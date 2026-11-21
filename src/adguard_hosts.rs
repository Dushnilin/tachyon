//! AdGuard Home & hosts blocklist compiler, background updater, and per-client
//! DNS block statistics stored in tmpfs (`runtime_state_dir()`).

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};
use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::Mutex as AsyncMutex;

use crate::core_mgr::CoreManager;
use crate::crypto_gen::{sha256_bytes_hex, write_file_if_changed, write_json_if_changed};
use crate::store::{
    AppState, RouterStoreData, mask_cidr, runtime_state_dir, unix_now_secs, valid_ip_with_zone,
};

pub const ADGUARD_COMPILED_FILE: &str = "adguard-compiled.json";
pub const HOSTS_LIST_STATUS_FILE: &str = "hosts-list-status.json";
pub const HOSTS_LIST_TXT_FILE: &str = "hosts-list.txt";
pub const DNS_BLOCK_STATS_FILE: &str = "dns-block-stats.json";

pub const TAG_ALLOW_IMPORTANT: &str = "adguard-allow-important";
pub const TAG_BLOCK_IMPORTANT: &str = "adguard-block-important";
pub const TAG_ALLOW: &str = "adguard-allow";
pub const TAG_BLOCK: &str = "adguard-block";

pub const MAX_LINES_PER_LIST: usize = 500_000;
pub const MAX_COMPILED_RULES: usize = 250_000;
pub const MAX_STATS_EVENTS: usize = 4_096;
const MAX_INGESTED_LOG_KEYS: usize = 2_048;
const MAX_RECENT_EVENTS_RETURNED: usize = 100;
const DEFAULT_UPDATE_INTERVAL_SECS: u64 = 86_400;
const MIN_UPDATE_INTERVAL_SECS: u64 = 300;
const MAX_UPDATE_INTERVAL_SECS: u64 = 30 * 86_400;

static STATS_FILE_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
static UPDATE_RUN_LOCK: OnceLock<AsyncMutex<()>> = OnceLock::new();
static TELEMETRY_SYNC_STATE: OnceLock<Mutex<TelemetrySyncState>> = OnceLock::new();

#[derive(Default)]
struct TelemetrySyncState {
    last_poll_secs: i64,
    seen_order: VecDeque<String>,
    seen_keys: HashSet<String>,
}

fn stats_lock() -> &'static Mutex<()> {
    STATS_FILE_LOCK.get_or_init(|| Mutex::new(()))
}

fn update_lock() -> &'static AsyncMutex<()> {
    UPDATE_RUN_LOCK.get_or_init(|| AsyncMutex::new(()))
}

fn telemetry_sync_state() -> &'static Mutex<TelemetrySyncState> {
    TELEMETRY_SYNC_STATE.get_or_init(|| Mutex::new(TelemetrySyncState::default()))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuleKind {
    Allow,
    Block,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MatchKind {
    Exact,
    Suffix,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct CompiledDomainRule {
    pub kind: RuleKind,
    #[serde(default)]
    pub important: bool,
    pub match_kind: MatchKind,
    pub domain: String,
    pub raw_rule: String,
    pub source: String,
    #[serde(default)]
    pub query_types: Vec<String>,
    #[serde(default)]
    pub client_cidrs: Vec<String>,
}

impl CompiledDomainRule {
    pub fn has_modifiers(&self) -> bool {
        !self.query_types.is_empty() || !self.client_cidrs.is_empty()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CompactRuleRef {
    pub src_idx: u16,
    /// bit 0: kind (1=Allow, 0=Block)
    /// bit 1: important
    /// bit 2: match_kind (1=Suffix, 0=Exact)
    /// bit 3: hosts syntax (`0.0.0.0 <domain>`)
    pub flags: u8,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub custom_rule: Option<String>,
}

impl CompactRuleRef {
    fn from_rule(src_idx: u16, rule: &CompiledDomainRule) -> Self {
        let mut flags = 0u8;
        if rule.kind == RuleKind::Allow {
            flags |= 1 << 0;
        }
        if rule.important {
            flags |= 1 << 1;
        }
        if rule.match_kind == MatchKind::Suffix {
            flags |= 1 << 2;
        }
        let is_hosts = rule.raw_rule.starts_with("0.0.0.0 ")
            || rule.raw_rule.starts_with("127.0.0.1 ")
            || rule.raw_rule.starts_with(":: ");
        if is_hosts {
            flags |= 1 << 3;
        }
        let canonical = format_canonical_rule(
            rule.kind,
            rule.important,
            rule.match_kind,
            &rule.domain,
            is_hosts,
        );
        let custom_rule = if canonical == rule.raw_rule {
            None
        } else {
            Some(rule.raw_rule.clone())
        };
        Self {
            src_idx,
            flags,
            custom_rule,
        }
    }

    pub fn kind(&self) -> RuleKind {
        if (self.flags & (1 << 0)) != 0 {
            RuleKind::Allow
        } else {
            RuleKind::Block
        }
    }

    pub fn important(&self) -> bool {
        (self.flags & (1 << 1)) != 0
    }

    pub fn match_kind(&self) -> MatchKind {
        if (self.flags & (1 << 2)) != 0 {
            MatchKind::Suffix
        } else {
            MatchKind::Exact
        }
    }

    pub fn rule_text(&self, domain: &str) -> String {
        if let Some(ref custom) = self.custom_rule {
            return custom.clone();
        }
        format_canonical_rule(
            self.kind(),
            self.important(),
            self.match_kind(),
            domain,
            (self.flags & (1 << 3)) != 0,
        )
    }
}

fn format_canonical_rule(
    kind: RuleKind,
    important: bool,
    match_kind: MatchKind,
    domain: &str,
    is_hosts: bool,
) -> String {
    if is_hosts && kind == RuleKind::Block && !important && match_kind == MatchKind::Exact {
        return format!("0.0.0.0 {domain}");
    }
    let prefix = if kind == RuleKind::Allow { "@@" } else { "" };
    let anchor = if match_kind == MatchKind::Suffix {
        "||"
    } else {
        "|"
    };
    let suffix = if important { "^$important" } else { "^" };
    format!("{prefix}{anchor}{domain}{suffix}")
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ListSourceStatus {
    pub url: String,
    #[serde(default)]
    pub format: String,
    pub entries: usize,
    pub block_rules: usize,
    pub allow_rules: usize,
    #[serde(default)]
    pub important_rules: usize,
    #[serde(default)]
    pub static_hosts: usize,
    #[serde(default)]
    pub ignored_lines: usize,
    pub ok: bool,
    #[serde(default)]
    pub cached_fallback: bool,
    #[serde(default)]
    pub error: String,
    #[serde(default)]
    pub sha256: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct CompiledAdguardIndex {
    pub version: u32,
    pub compiled_digest: String,
    pub updated_at: i64,
    #[serde(default)]
    pub urls: Vec<String>,
    pub total_block_rules: usize,
    pub total_allow_rules: usize,
    pub total_important_rules: usize,
    pub total_static_hosts: usize,
    #[serde(default)]
    pub static_hosts: BTreeMap<String, Vec<String>>,
    #[serde(default)]
    pub allow_important_exact: Vec<String>,
    #[serde(default)]
    pub allow_important_suffix: Vec<String>,
    #[serde(default)]
    pub block_important_exact: Vec<String>,
    #[serde(default)]
    pub block_important_suffix: Vec<String>,
    #[serde(default)]
    pub allow_exact: Vec<String>,
    #[serde(default)]
    pub allow_suffix: Vec<String>,
    #[serde(default)]
    pub block_exact: Vec<String>,
    #[serde(default)]
    pub block_suffix: Vec<String>,
    #[serde(default)]
    pub modifier_rules: Vec<CompiledDomainRule>,
    #[serde(default)]
    pub sources: Vec<ListSourceStatus>,
    /// Blocked domain/suffix -> compact rule attribution (priority: important first).
    #[serde(default)]
    pub block_exact_meta: BTreeMap<String, CompactRuleRef>,
    #[serde(default)]
    pub block_suffix_meta: BTreeMap<String, CompactRuleRef>,
    #[serde(default)]
    pub allow_exact_meta: BTreeMap<String, CompactRuleRef>,
    #[serde(default)]
    pub allow_suffix_meta: BTreeMap<String, CompactRuleRef>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ParsedInlineRules {
    pub static_hosts: BTreeMap<String, Vec<String>>,
    pub rules: Vec<CompiledDomainRule>,
}

#[derive(Debug, Clone, Default)]
pub struct ParsedListResult {
    pub rules: Vec<CompiledDomainRule>,
    pub static_hosts: BTreeMap<String, Vec<String>>,
    pub block_rules: usize,
    pub allow_rules: usize,
    pub important_rules: usize,
    pub ignored_lines: usize,
    pub detected_format: &'static str,
}

#[derive(Debug, Clone, Default)]
pub struct RuleMatchInfo {
    pub matched_rule: String,
    pub list_source: String,
    pub kind: Option<RuleKind>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DnsBlockEvent {
    pub timestamp_unix: i64,
    pub client_ip: String,
    #[serde(default)]
    pub client_name: String,
    pub domain: String,
    pub matched_rule: String,
    pub list_source: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct DnsBlockStatsStore {
    version: u32,
    max_events: usize,
    #[serde(default)]
    events: Vec<DnsBlockEvent>,
}

impl Default for DnsBlockStatsStore {
    fn default() -> Self {
        Self {
            version: 1,
            max_events: MAX_STATS_EVENTS,
            events: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DomainBlockStats {
    pub domain: String,
    pub count: u64,
    pub matched_rule: String,
    pub list_source: String,
    pub last_seen: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClientBlockStats {
    pub client_ip: String,
    pub client_name: String,
    pub blocked_count: u64,
    pub unique_domains: usize,
    pub last_seen: i64,
    pub top_domains: Vec<DomainBlockStats>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuleBlockStats {
    pub matched_rule: String,
    pub list_source: String,
    pub count: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ListBlockStats {
    pub list_source: String,
    pub count: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DnsBlockStatsResponse {
    pub ok: bool,
    pub period: String,
    pub generated_at: i64,
    pub total_blocked: u64,
    pub unique_clients: usize,
    pub unique_domains: usize,
    pub clients: Vec<ClientBlockStats>,
    pub top_domains: Vec<DomainBlockStats>,
    pub top_rules: Vec<RuleBlockStats>,
    pub top_lists: Vec<ListBlockStats>,
    pub recent_events: Vec<DnsBlockEvent>,
}

fn is_loopback_boilerplate_host(domain: &str) -> bool {
    matches!(
        domain,
        "localhost"
            | "localhost.localdomain"
            | "localhost4"
            | "localhost4.localdomain4"
            | "localhost6"
            | "localhost6.localdomain6"
            | "local"
            | "broadcasthost"
            | "ip6-localhost"
            | "ip6-loopback"
            | "ip6-localnet"
            | "ip6-mcastprefix"
            | "ip6-allnodes"
            | "ip6-allrouters"
            | "ip6-allhosts"
            | "0.0.0.0"
    )
}

fn is_sinkhole_ip(ip: &IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let oct = v4.octets();
            oct == [0, 0, 0, 0] || oct == [127, 0, 0, 1]
        }
        IpAddr::V6(v6) => v6.is_unspecified(),
    }
}

/// Normalize and validate a DNS rule hostname (no wildcards, no IPs, valid ASCII labels).
pub fn normalize_rule_domain(raw: &str) -> Option<String> {
    let trimmed = raw
        .trim()
        .trim_end_matches('.')
        .trim_start_matches('.')
        .to_ascii_lowercase();
    if trimmed.is_empty() || trimmed.len() > 253 {
        return None;
    }
    if trimmed.parse::<IpAddr>().is_ok() {
        return None;
    }
    if is_loopback_boilerplate_host(&trimmed) {
        return None;
    }
    let labels: Vec<&str> = trimmed.split('.').collect();
    if labels.len() < 2 {
        return None;
    }
    for label in labels {
        if label.is_empty() || label.len() > 63 {
            return None;
        }
        let bytes = label.as_bytes();
        if bytes[0] == b'-' || bytes[bytes.len() - 1] == b'-' {
            return None;
        }
        if !bytes
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || *b == b'-' || *b == b'_')
        {
            return None;
        }
    }
    Some(trimmed)
}

fn is_cosmetic_or_scriptlet_line(line: &str) -> bool {
    const MARKERS: &[&str] = &[
        "##", "#@#", "#?#", "#@?#", "#$#", "#@$#", "#%#", "#@%#", "$$", "$@#",
    ];
    MARKERS.iter().any(|m| line.contains(m))
}

fn strip_hosts_inline_comment(line: &str) -> &str {
    for (idx, ch) in line.char_indices() {
        if ch == '#' && (idx == 0 || line[..idx].ends_with(char::is_whitespace)) {
            return line[..idx].trim_end();
        }
    }
    line
}

fn normalize_client_cidr(token: &str) -> Option<String> {
    let clean = token.trim();
    if clean.is_empty() || clean.starts_with('~') {
        return None;
    }
    if clean.contains('/') {
        return mask_cidr(clean);
    }
    let ip: IpAddr = clean.parse().ok()?;
    Some(match ip {
        IpAddr::V4(v4) => format!("{v4}/32"),
        IpAddr::V6(v6) => format!("{v6}/128"),
    })
}

fn normalize_dns_qtype(token: &str) -> Option<String> {
    let up = token.trim().to_ascii_uppercase();
    match up.as_str() {
        "A" | "AAAA" | "HTTPS" | "SVCB" | "TXT" | "MX" | "CNAME" | "PTR" | "SRV" | "NS" | "SOA"
        | "CAA" | "ANY" => Some(up),
        _ => None,
    }
}

#[derive(Default)]
struct ParsedModifiers {
    important: bool,
    query_types: Vec<String>,
    client_cidrs: Vec<String>,
    rewrite_nxdomain: bool,
    rewrite_ip: Option<IpAddr>,
}

fn parse_adguard_modifiers(raw_mods: &str) -> Option<ParsedModifiers> {
    let trimmed = raw_mods.trim();
    if trimmed.is_empty() {
        return None;
    }
    let mut parsed = ParsedModifiers::default();
    let mut qset = BTreeSet::new();
    let mut cset = BTreeSet::new();

    for part in trimmed.split(',') {
        let m = part.trim();
        if m.is_empty() {
            return None;
        }
        let lower = m.to_ascii_lowercase();
        if lower == "important" {
            parsed.important = true;
            continue;
        }
        if let Some(val) = m
            .strip_prefix("dnstype=")
            .or_else(|| m.strip_prefix("DNSTYPE="))
        {
            let mut count = 0usize;
            for item in val.split('|') {
                let qt = normalize_dns_qtype(item)?;
                qset.insert(qt);
                count += 1;
            }
            if count == 0 {
                return None;
            }
            continue;
        }
        if let Some(val) = m
            .strip_prefix("client=")
            .or_else(|| m.strip_prefix("CLIENT="))
        {
            let mut count = 0usize;
            for item in val.split('|') {
                let cidr = normalize_client_cidr(item)?;
                cset.insert(cidr);
                count += 1;
            }
            if count == 0 {
                return None;
            }
            continue;
        }
        if let Some(val) = m
            .strip_prefix("dnsrewrite=")
            .or_else(|| m.strip_prefix("DNSREWRITE="))
        {
            let v = val.trim();
            if v.eq_ignore_ascii_case("nxdomain") {
                parsed.rewrite_nxdomain = true;
                continue;
            }
            if let Ok(ip) = v.parse::<IpAddr>() {
                parsed.rewrite_ip = Some(ip);
                continue;
            }
            // Support AdGuard `NOERROR;A;<ip>` / `NOERROR;AAAA;<ip>` shorthand.
            let segs: Vec<&str> = v.split(';').collect();
            if segs.len() == 3
                && segs[0].eq_ignore_ascii_case("noerror")
                && matches!(segs[1].to_ascii_uppercase().as_str(), "A" | "AAAA")
                && let Ok(ip) = segs[2].trim().parse::<IpAddr>()
            {
                parsed.rewrite_ip = Some(ip);
                continue;
            }
            return None;
        }
        // Any HTTP-only or unrecognized modifier (`badfilter`, `third-party`, `script`,
        // `domain=`, `removeparam`, `redirect`, etc.) is ignored safely for DNS filtering.
        return None;
    }

    parsed.query_types = qset.into_iter().collect();
    parsed.client_cidrs = cset.into_iter().collect();
    Some(parsed)
}

pub enum ParsedLineOutcome {
    Rules(Vec<CompiledDomainRule>),
    StaticHosts(Vec<(String, String)>),
    Ignored,
}

/// Parse a single hosts or AdGuard Home filter rule line.
pub fn parse_rule_line(raw_line: &str, source: &str) -> ParsedLineOutcome {
    let line = raw_line.trim().trim_start_matches('\u{feff}').trim();
    if line.is_empty()
        || line.starts_with('!')
        || line.starts_with('#')
        || line.starts_with('[')
        || is_cosmetic_or_scriptlet_line(line)
    {
        return ParsedLineOutcome::Ignored;
    }

    // Check hosts syntax (`IP dom1 dom2 ...` or `dom IP`) when whitespace exists and
    // line doesn't use AdGuard `@@` / `||` / `|` prefixes.
    if !line.starts_with("@@") && !line.starts_with("||") && !line.starts_with('|') {
        let no_comment = strip_hosts_inline_comment(line);
        let tokens: Vec<&str> = no_comment.split_whitespace().collect();
        if tokens.len() >= 2 {
            if let Ok(ip) = tokens[0].parse::<IpAddr>() {
                return parse_hosts_ip_first(ip, &tokens[1..], source);
            }
            if tokens.len() == 2
                && let Ok(ip) = tokens[1].parse::<IpAddr>()
            {
                return parse_hosts_ip_first(ip, &[tokens[0]], source);
            }
            return ParsedLineOutcome::Ignored;
        }
    }

    if line.chars().any(char::is_whitespace) {
        return ParsedLineOutcome::Ignored;
    }

    parse_adguard_rule_line(line, source)
}

fn parse_hosts_ip_first(ip: IpAddr, domain_tokens: &[&str], source: &str) -> ParsedLineOutcome {
    let ip_str = ip.to_string();
    if is_sinkhole_ip(&ip) {
        let mut rules = Vec::new();
        for tok in domain_tokens {
            if let Some(dom) = normalize_rule_domain(tok) {
                rules.push(CompiledDomainRule {
                    kind: RuleKind::Block,
                    important: false,
                    match_kind: MatchKind::Exact,
                    raw_rule: format!("{ip_str} {dom}"),
                    domain: dom,
                    source: source.to_string(),
                    query_types: Vec::new(),
                    client_cidrs: Vec::new(),
                });
            }
        }
        if rules.is_empty() {
            ParsedLineOutcome::Ignored
        } else {
            ParsedLineOutcome::Rules(rules)
        }
    } else if !ip.is_loopback() && !ip.is_multicast() {
        let mut pairs = Vec::new();
        for tok in domain_tokens {
            if let Some(dom) = normalize_rule_domain(tok) {
                pairs.push((dom, ip_str.clone()));
            }
        }
        if pairs.is_empty() {
            ParsedLineOutcome::Ignored
        } else {
            ParsedLineOutcome::StaticHosts(pairs)
        }
    } else {
        ParsedLineOutcome::Ignored
    }
}

fn parse_adguard_rule_line(line: &str, source: &str) -> ParsedLineOutcome {
    let (body_no_mods, mods) = if let Some((left, right)) = line.split_once('$') {
        let Some(parsed) = parse_adguard_modifiers(right) else {
            return ParsedLineOutcome::Ignored;
        };
        (left, parsed)
    } else {
        (line, ParsedModifiers::default())
    };

    let (is_allow, pattern) = if let Some(rest) = body_no_mods.strip_prefix("@@") {
        (true, rest)
    } else {
        (false, body_no_mods)
    };

    if pattern.is_empty()
        || (pattern.starts_with('/') && pattern.ends_with('/'))
        || pattern.contains("://")
        || pattern.contains('/')
        || pattern.contains('?')
        || pattern.contains('=')
        || pattern.contains('@')
        || pattern.contains('!')
        || pattern.contains('[')
        || pattern.contains(']')
        || pattern.contains('(')
        || pattern.contains(')')
        || pattern.contains('\\')
    {
        return ParsedLineOutcome::Ignored;
    }

    let (match_kind, raw_dom) = if let Some(rest) = pattern.strip_prefix("||") {
        let clean = rest
            .strip_suffix('^')
            .unwrap_or(rest)
            .strip_prefix("*.")
            .unwrap_or_else(|| rest.strip_suffix('^').unwrap_or(rest));
        (MatchKind::Suffix, clean)
    } else if let Some(rest) = pattern.strip_prefix('|') {
        let clean = rest.strip_suffix('^').unwrap_or(rest);
        (MatchKind::Exact, clean)
    } else if let Some(rest) = pattern.strip_prefix("*.") {
        let clean = rest.strip_suffix('^').unwrap_or(rest);
        (MatchKind::Suffix, clean)
    } else {
        let clean = pattern.strip_suffix('^').unwrap_or(pattern);
        (MatchKind::Exact, clean)
    };

    if raw_dom.contains('*') || raw_dom.contains('^') || raw_dom.contains('|') {
        return ParsedLineOutcome::Ignored;
    }

    let Some(domain) = normalize_rule_domain(raw_dom) else {
        return ParsedLineOutcome::Ignored;
    };

    if let Some(ip) = mods.rewrite_ip {
        if is_allow {
            return ParsedLineOutcome::Ignored;
        }
        if is_sinkhole_ip(&ip) {
            return ParsedLineOutcome::Rules(vec![CompiledDomainRule {
                kind: RuleKind::Block,
                important: mods.important,
                match_kind,
                domain,
                raw_rule: line.to_string(),
                source: source.to_string(),
                query_types: mods.query_types,
                client_cidrs: mods.client_cidrs,
            }]);
        }
        if !ip.is_loopback() && !ip.is_multicast() && mods.query_types.is_empty() {
            return ParsedLineOutcome::StaticHosts(vec![(domain, ip.to_string())]);
        }
        return ParsedLineOutcome::Ignored;
    }

    let kind = if is_allow && !mods.rewrite_nxdomain {
        RuleKind::Allow
    } else {
        RuleKind::Block
    };

    ParsedLineOutcome::Rules(vec![CompiledDomainRule {
        kind,
        important: mods.important,
        match_kind,
        domain,
        raw_rule: line.to_string(),
        source: source.to_string(),
        query_types: mods.query_types,
        client_cidrs: mods.client_cidrs,
    }])
}

/// Parse an entire downloaded or inline hosts/AdGuard filter list.
pub fn parse_list_content(content: &str, source: &str) -> ParsedListResult {
    let mut out = ParsedListResult::default();
    let mut adguard_seen = 0usize;
    let mut hosts_seen = 0usize;

    for raw_line in content.lines().take(MAX_LINES_PER_LIST) {
        match parse_rule_line(raw_line, source) {
            ParsedLineOutcome::Rules(rules) => {
                for r in rules {
                    if out.rules.len() >= MAX_COMPILED_RULES {
                        break;
                    }
                    if r.raw_rule.starts_with("0.0.0.0 ")
                        || r.raw_rule.starts_with("127.0.0.1 ")
                        || r.raw_rule.starts_with(":: ")
                    {
                        hosts_seen += 1;
                    } else {
                        adguard_seen += 1;
                    }
                    if r.important {
                        out.important_rules += 1;
                    }
                    match r.kind {
                        RuleKind::Allow => out.allow_rules += 1,
                        RuleKind::Block => out.block_rules += 1,
                    }
                    out.rules.push(r);
                }
            }
            ParsedLineOutcome::StaticHosts(pairs) => {
                hosts_seen += pairs.len();
                for (dom, ip) in pairs {
                    let entry = out.static_hosts.entry(dom).or_default();
                    if !entry.contains(&ip) {
                        entry.push(ip);
                    }
                }
            }
            ParsedLineOutcome::Ignored => {
                let t = raw_line.trim();
                if !t.is_empty()
                    && !t.starts_with('#')
                    && !t.starts_with('!')
                    && !t.starts_with('[')
                {
                    out.ignored_lines += 1;
                }
            }
        }
    }

    out.detected_format = if adguard_seen > 0 && hosts_seen > 0 {
        "mixed"
    } else if adguard_seen > 0 {
        "adguard"
    } else if hosts_seen > 0 {
        "hosts"
    } else {
        "empty"
    };
    out
}

/// Collect unique, enabled remote list URLs from global settings and enabled routing sections.
pub fn collect_active_hosts_list_urls(store: &RouterStoreData) -> Vec<String> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();

    for raw in &store.settings.hosts_list_urls {
        let u = raw.trim();
        if !u.is_empty() && seen.insert(u.to_string()) {
            out.push(u.to_string());
        }
    }

    for sec in &store.sections {
        if !sec.enabled {
            continue;
        }
        let disabled: HashSet<&str> = sec
            .hosts_list_disabled
            .iter()
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .collect();
        for raw in &sec.hosts_list_urls {
            let u = raw.trim();
            if !u.is_empty() && !disabled.contains(u) && seen.insert(u.to_string()) {
                out.push(u.to_string());
            }
        }
    }

    out
}

/// Parse inline hosts and AdGuard rules from `store.settings.static_hosts` and enabled
/// routing sections' `dns_hosts`.
pub fn collect_inline_rules(store: &RouterStoreData) -> ParsedInlineRules {
    let mut out = ParsedInlineRules::default();

    let mut append_parsed = |parsed: ParsedListResult| {
        for (dom, ips) in parsed.static_hosts {
            let bucket = out.static_hosts.entry(dom).or_default();
            for ip in ips {
                if !bucket.contains(&ip) {
                    bucket.push(ip);
                }
            }
        }
        for rule in parsed.rules {
            if out.rules.len() >= MAX_COMPILED_RULES {
                break;
            }
            out.rules.push(rule);
        }
    };

    if !store.settings.static_hosts.is_empty() {
        let joined = store.settings.static_hosts.join("\n");
        append_parsed(parse_list_content(&joined, "inline:global"));
    }

    for sec in &store.sections {
        if !sec.enabled || sec.dns_hosts.trim().is_empty() {
            continue;
        }
        let sec_name = if sec.label.trim().is_empty() {
            sec.id.as_str()
        } else {
            sec.label.as_str()
        };
        let src = format!("inline:{sec_name}");
        append_parsed(parse_list_content(&sec.dns_hosts, &src));
    }

    out
}

/// Parse update interval tokens (`30m`, `1h`, `6h`, `12h`, `24h`, `7d`, or seconds) safely.
pub fn parse_update_interval_secs(raw: &str) -> u64 {
    let s = raw.trim().to_ascii_lowercase();
    if s.is_empty() {
        return DEFAULT_UPDATE_INTERVAL_SECS;
    }
    let secs = if let Some(n) = s.strip_suffix('d') {
        n.trim()
            .parse::<u64>()
            .ok()
            .map(|v| v.saturating_mul(86_400))
    } else if let Some(n) = s.strip_suffix('h') {
        n.trim()
            .parse::<u64>()
            .ok()
            .map(|v| v.saturating_mul(3_600))
    } else if let Some(n) = s.strip_suffix('m') {
        n.trim().parse::<u64>().ok().map(|v| v.saturating_mul(60))
    } else if let Some(n) = s.strip_suffix('s') {
        n.trim().parse::<u64>().ok()
    } else {
        s.parse::<u64>().ok()
    };
    secs.unwrap_or(DEFAULT_UPDATE_INTERVAL_SECS)
        .clamp(MIN_UPDATE_INTERVAL_SECS, MAX_UPDATE_INTERVAL_SECS)
}

fn auto_update_schedule(store: &RouterStoreData) -> Option<u64> {
    let mut enabled = false;
    let mut min_interval = MAX_UPDATE_INTERVAL_SECS;

    if store.settings.hosts_list_auto_update && !store.settings.hosts_list_urls.is_empty() {
        enabled = true;
        min_interval = min_interval.min(parse_update_interval_secs(
            &store.settings.hosts_list_update_interval,
        ));
    }
    for sec in &store.sections {
        if sec.enabled && sec.hosts_list_auto_update && !sec.hosts_list_urls.is_empty() {
            enabled = true;
            min_interval =
                min_interval.min(parse_update_interval_secs(&sec.hosts_list_update_interval));
        }
    }

    if enabled { Some(min_interval) } else { None }
}

fn insert_meta_if_higher_priority(
    map: &mut BTreeMap<String, CompactRuleRef>,
    domain: &str,
    cand: CompactRuleRef,
) {
    match map.get(domain) {
        Some(existing) if existing.important() && !cand.important() => {}
        Some(_) => {
            if !cand.important() {
                // Keep first-listed source for deterministic attribution at equal priority.
                return;
            }
            map.insert(domain.to_string(), cand);
        }
        None => {
            map.insert(domain.to_string(), cand);
        }
    }
}

/// Compile downloaded remote lists and persist tmpfs artifacts cleanly.
/// Returns `(CompiledAdguardIndex, rules_changed_on_disk)`.
pub fn compile_and_store_remote_lists_in(
    rt_dir: &Path,
    fetched: &[(String, String, bool, String)], // (url, body, ok_fetch, err_msg)
    now_unix: i64,
) -> anyhow::Result<(CompiledAdguardIndex, bool)> {
    let mut allow_imp_exact = BTreeSet::new();
    let mut allow_imp_suffix = BTreeSet::new();
    let mut block_imp_exact = BTreeSet::new();
    let mut block_imp_suffix = BTreeSet::new();
    let mut allow_exact = BTreeSet::new();
    let mut allow_suffix = BTreeSet::new();
    let mut block_exact = BTreeSet::new();
    let mut block_suffix = BTreeSet::new();
    let mut modifier_rules_set = BTreeSet::new();
    let mut static_hosts: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut sources: Vec<ListSourceStatus> = Vec::with_capacity(fetched.len());
    let mut block_exact_meta: BTreeMap<String, CompactRuleRef> = BTreeMap::new();
    let mut block_suffix_meta: BTreeMap<String, CompactRuleRef> = BTreeMap::new();
    let mut allow_exact_meta: BTreeMap<String, CompactRuleRef> = BTreeMap::new();
    let mut allow_suffix_meta: BTreeMap<String, CompactRuleRef> = BTreeMap::new();
    let mut urls: Vec<String> = Vec::with_capacity(fetched.len());

    let mut total_block_rules = 0usize;
    let mut total_allow_rules = 0usize;
    let mut total_important_rules = 0usize;

    for (idx, (url, body, ok_fetch, err_msg)) in fetched.iter().enumerate() {
        let src_idx = u16::try_from(idx).unwrap_or(u16::MAX);
        urls.push(url.clone());
        let parsed = parse_list_content(body, url);
        let static_count: usize = parsed.static_hosts.values().map(Vec::len).sum();
        sources.push(ListSourceStatus {
            url: url.clone(),
            format: parsed.detected_format.to_string(),
            entries: parsed.rules.len() + static_count,
            block_rules: parsed.block_rules,
            allow_rules: parsed.allow_rules,
            important_rules: parsed.important_rules,
            static_hosts: static_count,
            ignored_lines: parsed.ignored_lines,
            ok: *ok_fetch,
            cached_fallback: !*ok_fetch && !body.is_empty(),
            error: err_msg.clone(),
            sha256: if body.is_empty() {
                String::new()
            } else {
                sha256_bytes_hex(body.as_bytes())
            },
        });

        for (dom, ips) in parsed.static_hosts {
            let bucket = static_hosts.entry(dom).or_default();
            for ip in ips {
                if !bucket.contains(&ip) {
                    bucket.push(ip);
                }
            }
        }

        for rule in parsed.rules {
            if total_block_rules + total_allow_rules >= MAX_COMPILED_RULES {
                break;
            }
            if rule.important {
                total_important_rules += 1;
            }
            match rule.kind {
                RuleKind::Allow => total_allow_rules += 1,
                RuleKind::Block => total_block_rules += 1,
            }

            if rule.has_modifiers() {
                modifier_rules_set.insert(rule);
                continue;
            }

            let meta = CompactRuleRef::from_rule(src_idx, &rule);
            match (rule.kind, rule.important, rule.match_kind) {
                (RuleKind::Allow, true, MatchKind::Exact) => {
                    allow_imp_exact.insert(rule.domain.clone());
                    insert_meta_if_higher_priority(&mut allow_exact_meta, &rule.domain, meta);
                }
                (RuleKind::Allow, true, MatchKind::Suffix) => {
                    allow_imp_suffix.insert(rule.domain.clone());
                    insert_meta_if_higher_priority(&mut allow_suffix_meta, &rule.domain, meta);
                }
                (RuleKind::Block, true, MatchKind::Exact) => {
                    block_imp_exact.insert(rule.domain.clone());
                    insert_meta_if_higher_priority(&mut block_exact_meta, &rule.domain, meta);
                }
                (RuleKind::Block, true, MatchKind::Suffix) => {
                    block_imp_suffix.insert(rule.domain.clone());
                    insert_meta_if_higher_priority(&mut block_suffix_meta, &rule.domain, meta);
                }
                (RuleKind::Allow, false, MatchKind::Exact) => {
                    allow_exact.insert(rule.domain.clone());
                    insert_meta_if_higher_priority(&mut allow_exact_meta, &rule.domain, meta);
                }
                (RuleKind::Allow, false, MatchKind::Suffix) => {
                    allow_suffix.insert(rule.domain.clone());
                    insert_meta_if_higher_priority(&mut allow_suffix_meta, &rule.domain, meta);
                }
                (RuleKind::Block, false, MatchKind::Exact) => {
                    block_exact.insert(rule.domain.clone());
                    insert_meta_if_higher_priority(&mut block_exact_meta, &rule.domain, meta);
                }
                (RuleKind::Block, false, MatchKind::Suffix) => {
                    block_suffix.insert(rule.domain.clone());
                    insert_meta_if_higher_priority(&mut block_suffix_meta, &rule.domain, meta);
                }
            }
        }
    }

    let allow_important_exact: Vec<String> = allow_imp_exact.into_iter().collect();
    let allow_important_suffix: Vec<String> = allow_imp_suffix.into_iter().collect();
    let block_important_exact: Vec<String> = block_imp_exact.into_iter().collect();
    let block_important_suffix: Vec<String> = block_imp_suffix.into_iter().collect();
    let allow_exact: Vec<String> = allow_exact.into_iter().collect();
    let allow_suffix: Vec<String> = allow_suffix.into_iter().collect();
    let block_exact: Vec<String> = block_exact.into_iter().collect();
    let block_suffix: Vec<String> = block_suffix.into_iter().collect();
    let modifier_rules: Vec<CompiledDomainRule> = modifier_rules_set.into_iter().collect();
    let total_static_hosts: usize = static_hosts.values().map(Vec::len).sum();

    let digest_input = serde_json::to_vec(&json!({
        "allow_important_exact": allow_important_exact,
        "allow_important_suffix": allow_important_suffix,
        "block_important_exact": block_important_exact,
        "block_important_suffix": block_important_suffix,
        "allow_exact": allow_exact,
        "allow_suffix": allow_suffix,
        "block_exact": block_exact,
        "block_suffix": block_suffix,
        "modifier_rules": modifier_rules,
        "static_hosts": static_hosts,
    }))?;
    let compiled_digest = sha256_bytes_hex(&digest_input);

    let prev_digest = load_compiled_index_in(rt_dir)
        .map(|p| p.compiled_digest)
        .unwrap_or_default();

    let index = CompiledAdguardIndex {
        version: 1,
        compiled_digest: compiled_digest.clone(),
        updated_at: now_unix,
        urls: urls.clone(),
        total_block_rules,
        total_allow_rules,
        total_important_rules,
        total_static_hosts,
        static_hosts,
        allow_important_exact,
        allow_important_suffix,
        block_important_exact,
        block_important_suffix,
        allow_exact,
        allow_suffix,
        block_exact,
        block_suffix,
        modifier_rules,
        sources: sources.clone(),
        block_exact_meta,
        block_suffix_meta,
        allow_exact_meta,
        allow_suffix_meta,
    };

    let mut ruleset_changed = prev_digest != compiled_digest;
    ruleset_changed |= write_ruleset_bucket_in(
        rt_dir,
        TAG_ALLOW_IMPORTANT,
        &index.allow_important_exact,
        &index.allow_important_suffix,
    )?;
    ruleset_changed |= write_ruleset_bucket_in(
        rt_dir,
        TAG_BLOCK_IMPORTANT,
        &index.block_important_exact,
        &index.block_important_suffix,
    )?;
    ruleset_changed |=
        write_ruleset_bucket_in(rt_dir, TAG_ALLOW, &index.allow_exact, &index.allow_suffix)?;
    ruleset_changed |=
        write_ruleset_bucket_in(rt_dir, TAG_BLOCK, &index.block_exact, &index.block_suffix)?;

    let txt_payload = build_compat_hosts_txt(&index);
    let _ = write_file_if_changed(rt_dir.join(HOSTS_LIST_TXT_FILE), txt_payload.as_bytes())?;
    let _ = write_json_if_changed(rt_dir.join(ADGUARD_COMPILED_FILE), &index)?;

    let errors: Vec<String> = sources
        .iter()
        .filter(|s| !s.ok && !s.error.is_empty())
        .map(|s| s.error.clone())
        .collect();
    let status_doc = json!({
        "updated_at": now_unix,
        "entries": total_block_rules + total_allow_rules + total_static_hosts,
        "block_rules": total_block_rules,
        "allow_rules": total_allow_rules,
        "important_rules": total_important_rules,
        "static_hosts": total_static_hosts,
        "urls_count": urls.len(),
        "compiled_digest": compiled_digest,
        "errors": errors,
        "sources": sources,
    });
    let _ = write_json_if_changed(rt_dir.join(HOSTS_LIST_STATUS_FILE), &status_doc)?;

    Ok((index, ruleset_changed))
}

fn write_ruleset_bucket_in(
    rt_dir: &Path,
    tag: &str,
    exact: &[String],
    suffix: &[String],
) -> anyhow::Result<bool> {
    let path = rt_dir.join(format!("{tag}.json"));
    if exact.is_empty() && suffix.is_empty() {
        if path.exists() {
            return write_file_if_changed(&path, br#"{"version":3,"rules":[]}"#);
        }
        return Ok(false);
    }
    let mut rule_obj = serde_json::Map::new();
    if !exact.is_empty() {
        rule_obj.insert("domain".into(), json!(exact));
    }
    if !suffix.is_empty() {
        rule_obj.insert("domain_suffix".into(), json!(suffix));
    }
    let doc = json!({
        "version": 3,
        "rules": [Value::Object(rule_obj)],
    });
    let bytes = serde_json::to_vec(&doc)?;
    write_file_if_changed(&path, &bytes)
}

fn build_compat_hosts_txt(index: &CompiledAdguardIndex) -> String {
    let mut doms = BTreeSet::new();
    for d in &index.block_important_exact {
        doms.insert(d.as_str());
    }
    for d in &index.block_exact {
        doms.insert(d.as_str());
    }
    for d in &index.block_important_suffix {
        doms.insert(d.as_str());
    }
    for d in &index.block_suffix {
        doms.insert(d.as_str());
    }
    let mut out = String::new();
    for d in doms {
        out.push_str("0.0.0.0 ");
        out.push_str(d);
        out.push('\n');
    }
    out
}

pub fn load_compiled_index_in(rt_dir: &Path) -> Option<CompiledAdguardIndex> {
    let path = rt_dir.join(ADGUARD_COMPILED_FILE);
    let raw = std::fs::read_to_string(path).ok()?;
    serde_json::from_str::<CompiledAdguardIndex>(&raw).ok()
}

pub fn ruleset_file_has_entries(path: &Path) -> bool {
    let Ok(raw) = std::fs::read_to_string(path) else {
        return false;
    };
    let Ok(val) = serde_json::from_str::<Value>(&raw) else {
        return false;
    };
    val.get("rules")
        .and_then(Value::as_array)
        .is_some_and(|arr| {
            arr.iter().any(|r| {
                r.get("domain")
                    .and_then(Value::as_array)
                    .is_some_and(|d| !d.is_empty())
                    || r.get("domain_suffix")
                        .and_then(Value::as_array)
                        .is_some_and(|d| !d.is_empty())
            })
        })
}

fn cache_path_for_url(rt_dir: &Path, url: &str) -> PathBuf {
    let h = sha256_bytes_hex(url.as_bytes());
    let short = &h[..16.min(h.len())];
    rt_dir.join("hosts-cache").join(format!("{short}.txt"))
}

/// Download configured remote hosts/AdGuard lists, compile rules to tmpfs, and optionally
/// reload `tachyon-core` ONLY when compiled rules changed.
pub async fn update_hosts_lists_in(
    rt_dir: &Path,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    trigger_reload_on_change: bool,
) -> anyhow::Result<Value> {
    let _guard = update_lock().lock().await;
    let store = { state.data.read().await.clone() };
    let urls = collect_active_hosts_list_urls(&store);
    let mut fetched: Vec<(String, String, bool, String)> = Vec::with_capacity(urls.len());

    for url in &urls {
        let cache_file = cache_path_for_url(rt_dir, url);
        match core
            .curl_fetch_with_doh_fallback(url, false, 15, None)
            .await
        {
            Ok(bytes) => {
                let text = String::from_utf8_lossy(&bytes).into_owned();
                let _ = write_file_if_changed(&cache_file, text.as_bytes());
                fetched.push((url.clone(), text, true, String::new()));
            }
            Err(err) => {
                let cached = std::fs::read_to_string(&cache_file).unwrap_or_default();
                fetched.push((url.clone(), cached, false, format!("{url}: {err}")));
            }
        }
    }

    let now = unix_now_secs();
    let (index, changed) = compile_and_store_remote_lists_in(rt_dir, &fetched, now)?;

    let mut reloaded = false;
    if trigger_reload_on_change && changed {
        let running = { state.live.read().await.core_running };
        if running && core.apply_or_reload().await.is_ok() {
            reloaded = true;
        }
    }

    let errors: Vec<String> = index
        .sources
        .iter()
        .filter(|s| !s.ok && !s.error.is_empty())
        .map(|s| s.error.clone())
        .collect();
    let inline = collect_inline_rules(&store);
    let total_entries = index.total_block_rules
        + index.total_allow_rules
        + index.total_static_hosts
        + inline.rules.len();

    Ok(json!({
        "ok": errors.is_empty(),
        "success": errors.is_empty(),
        "status": if errors.is_empty() { "completed" } else { "partial" },
        "running": false,
        "completed": true,
        "entries": total_entries,
        "block_rules": index.total_block_rules,
        "allow_rules": index.total_allow_rules,
        "important_rules": index.total_important_rules,
        "static_hosts": index.total_static_hosts,
        "urls": index.urls.len(),
        "urls_count": index.urls.len(),
        "changed": changed,
        "reloaded": reloaded,
        "updated_at": now,
        "errors": errors,
        "sources": index.sources,
    }))
}

pub async fn update_hosts_lists(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    trigger_reload_on_change: bool,
) -> anyhow::Result<Value> {
    update_hosts_lists_in(&runtime_state_dir(), state, core, trigger_reload_on_change).await
}

/// Read current status of hosts/AdGuard lists from tmpfs without disk writes.
pub fn get_hosts_list_status_in(rt_dir: &Path, store: &RouterStoreData) -> Value {
    let urls = collect_active_hosts_list_urls(store);
    let inline = collect_inline_rules(store);
    let status_path = rt_dir.join(HOSTS_LIST_STATUS_FILE);

    if let Ok(raw) = std::fs::read_to_string(&status_path)
        && let Ok(mut parsed) = serde_json::from_str::<Value>(&raw)
        && let Some(obj) = parsed.as_object_mut()
    {
        let has_errors = obj
            .get("errors")
            .and_then(Value::as_array)
            .is_some_and(|e| !e.is_empty());
        obj.insert("ok".into(), json!(true));
        obj.insert("success".into(), json!(!has_errors));
        obj.entry("status").or_insert_with(|| json!("completed"));
        obj.insert("running".into(), json!(false));
        obj.insert("completed".into(), json!(true));
        obj.insert("urls_count".into(), json!(urls.len()));
        obj.insert("inline_rules".into(), json!(inline.rules.len()));
        obj.insert(
            "auto_update".into(),
            json!(auto_update_schedule(store).is_some()),
        );
        return Value::Object(obj.clone());
    }

    json!({
        "ok": true,
        "success": true,
        "status": "idle",
        "running": false,
        "completed": false,
        "entries": inline.rules.len() + inline.static_hosts.values().map(Vec::len).sum::<usize>(),
        "block_rules": inline.rules.iter().filter(|r| r.kind == RuleKind::Block).count(),
        "allow_rules": inline.rules.iter().filter(|r| r.kind == RuleKind::Allow).count(),
        "important_rules": inline.rules.iter().filter(|r| r.important).count(),
        "static_hosts": inline.static_hosts.values().map(Vec::len).sum::<usize>(),
        "inline_rules": inline.rules.len(),
        "urls_count": urls.len(),
        "updated_at": 0,
        "auto_update": auto_update_schedule(store).is_some(),
        "errors": [],
        "sources": []
    })
}

pub fn get_hosts_list_status(store: &RouterStoreData) -> Value {
    get_hosts_list_status_in(&runtime_state_dir(), store)
}

fn match_domain_in_meta_map<'a>(
    map: &'a BTreeMap<String, CompactRuleRef>,
    domain: &str,
    suffix_mode: bool,
) -> Option<(String, &'a CompactRuleRef)> {
    if !suffix_mode {
        return map.get(domain).map(|r| (domain.to_string(), r));
    }
    let mut cur: Option<&str> = Some(domain);
    while let Some(d) = cur {
        if let Some(r) = map.get(d) {
            return Some((d.to_string(), r));
        }
        cur = d.split_once('.').map(|(_, rest)| rest);
    }
    None
}

fn rule_matches_domain(rule: &CompiledDomainRule, domain: &str) -> bool {
    match rule.match_kind {
        MatchKind::Exact => domain == rule.domain,
        MatchKind::Suffix => {
            domain == rule.domain
                || (domain.len() > rule.domain.len()
                    && domain.ends_with(&rule.domain)
                    && domain.as_bytes()[domain.len() - rule.domain.len() - 1] == b'.')
        }
    }
}

fn client_matches_cidrs(client_ip: &str, cidrs: &[String]) -> bool {
    if cidrs.is_empty() {
        return true;
    }
    if client_ip.is_empty() {
        return false;
    }
    cidrs.iter().any(|c| crate::store::ip_in_cidr(client_ip, c))
}

fn find_inline_match(
    inline: &ParsedInlineRules,
    domain: &str,
    client_ip: &str,
    kind: RuleKind,
    important: bool,
) -> Option<RuleMatchInfo> {
    for r in &inline.rules {
        if r.kind == kind
            && r.important == important
            && rule_matches_domain(r, domain)
            && client_matches_cidrs(client_ip, &r.client_cidrs)
        {
            return Some(RuleMatchInfo {
                matched_rule: r.raw_rule.clone(),
                list_source: r.source.clone(),
                kind: Some(r.kind),
            });
        }
    }
    None
}

fn find_compiled_match(
    index: &CompiledAdguardIndex,
    domain: &str,
    client_ip: &str,
    kind: RuleKind,
    important: bool,
) -> Option<RuleMatchInfo> {
    let source_name = |src_idx: u16| -> String {
        index
            .sources
            .get(src_idx as usize)
            .map(|s| s.url.clone())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "list".to_string())
    };

    for r in &index.modifier_rules {
        if r.kind == kind
            && r.important == important
            && rule_matches_domain(r, domain)
            && client_matches_cidrs(client_ip, &r.client_cidrs)
        {
            return Some(RuleMatchInfo {
                matched_rule: r.raw_rule.clone(),
                list_source: r.source.clone(),
                kind: Some(r.kind),
            });
        }
    }

    let (exact_map, suffix_map) = match kind {
        RuleKind::Allow => (&index.allow_exact_meta, &index.allow_suffix_meta),
        RuleKind::Block => (&index.block_exact_meta, &index.block_suffix_meta),
    };
    if let Some((pat_dom, meta)) = match_domain_in_meta_map(exact_map, domain, false)
        && meta.important() == important
    {
        return Some(RuleMatchInfo {
            matched_rule: meta.rule_text(&pat_dom),
            list_source: source_name(meta.src_idx),
            kind: Some(kind),
        });
    }
    if let Some((pat_dom, meta)) = match_domain_in_meta_map(suffix_map, domain, true)
        && meta.important() == important
    {
        return Some(RuleMatchInfo {
            matched_rule: meta.rule_text(&pat_dom),
            list_source: source_name(meta.src_idx),
            kind: Some(kind),
        });
    }
    None
}

/// Resolve the winning block/allow rule and source list for a domain across inline and
/// compiled remote lists respecting tier priority:
/// Tier 1: `@@...$important` -> Tier 2: `...$important` -> Tier 3: `@@...` -> Tier 4: block.
pub fn resolve_rule_for_domain(
    domain: &str,
    client_ip: &str,
    store: &RouterStoreData,
    index: Option<&CompiledAdguardIndex>,
) -> Option<RuleMatchInfo> {
    let norm = domain.trim().trim_end_matches('.').to_ascii_lowercase();
    if norm.is_empty() {
        return None;
    }
    let inline = collect_inline_rules(store);

    // Tier 1: @@$important
    if let Some(m) = find_inline_match(&inline, &norm, client_ip, RuleKind::Allow, true) {
        return Some(m);
    }
    if let Some(idx) = index
        && let Some(m) = find_compiled_match(idx, &norm, client_ip, RuleKind::Allow, true)
    {
        return Some(m);
    }

    // Tier 2: block$important
    if let Some(m) = find_inline_match(&inline, &norm, client_ip, RuleKind::Block, true) {
        return Some(m);
    }
    if let Some(idx) = index
        && let Some(m) = find_compiled_match(idx, &norm, client_ip, RuleKind::Block, true)
    {
        return Some(m);
    }

    // Tier 3: @@ normal
    if let Some(m) = find_inline_match(&inline, &norm, client_ip, RuleKind::Allow, false) {
        return Some(m);
    }
    if let Some(idx) = index
        && let Some(m) = find_compiled_match(idx, &norm, client_ip, RuleKind::Allow, false)
    {
        return Some(m);
    }

    // Tier 4: normal block
    if let Some(m) = find_inline_match(&inline, &norm, client_ip, RuleKind::Block, false) {
        return Some(m);
    }
    if let Some(idx) = index
        && let Some(m) = find_compiled_match(idx, &norm, client_ip, RuleKind::Block, false)
    {
        return Some(m);
    }

    None
}

fn resolve_block_attribution(
    domain: &str,
    client_ip: &str,
    rule_hint: &str,
    list_hint: &str,
    store: &RouterStoreData,
    index: Option<&CompiledAdguardIndex>,
) -> (String, String) {
    let norm = domain.trim().trim_end_matches('.').to_ascii_lowercase();
    let inline = collect_inline_rules(store);

    for important in [true, false] {
        if let Some(m) = find_inline_match(&inline, &norm, client_ip, RuleKind::Block, important) {
            return (m.matched_rule, m.list_source);
        }
        if let Some(idx) = index
            && let Some(m) = find_compiled_match(idx, &norm, client_ip, RuleKind::Block, important)
        {
            return (m.matched_rule, m.list_source);
        }
    }

    let fallback_rule = if !rule_hint.trim().is_empty()
        && (rule_hint.starts_with("||")
            || rule_hint.starts_with('|')
            || rule_hint.starts_with("0.0.0.0 "))
    {
        rule_hint.trim().to_string()
    } else {
        format!("||{norm}^")
    };
    let fallback_src = if !list_hint.trim().is_empty() {
        list_hint.trim().to_string()
    } else {
        TAG_BLOCK.to_string()
    };
    (fallback_rule, fallback_src)
}

fn load_stats_store_locked(rt_dir: &Path) -> DnsBlockStatsStore {
    let path = rt_dir.join(DNS_BLOCK_STATS_FILE);
    let Ok(raw) = std::fs::read_to_string(path) else {
        return DnsBlockStatsStore::default();
    };
    serde_json::from_str::<DnsBlockStatsStore>(&raw).unwrap_or_default()
}

fn save_stats_store_locked(rt_dir: &Path, store: &DnsBlockStatsStore) -> anyhow::Result<bool> {
    write_json_if_changed(rt_dir.join(DNS_BLOCK_STATS_FILE), store)
}

fn push_event_into_store(store: &mut DnsBlockStatsStore, mut event: DnsBlockEvent) {
    event.domain = event
        .domain
        .trim()
        .trim_end_matches('.')
        .to_ascii_lowercase();
    event.client_ip = event.client_ip.trim().to_string();
    event.client_name = event.client_name.trim().to_string();
    event.matched_rule = event.matched_rule.trim().to_string();
    event.list_source = event.list_source.trim().to_string();

    if event.domain.is_empty() {
        return;
    }
    if event.client_ip.is_empty() {
        event.client_ip = "unknown".to_string();
    }
    if event.matched_rule.is_empty() {
        event.matched_rule = format!("||{}^", event.domain);
    }
    if event.list_source.is_empty() {
        event.list_source = TAG_BLOCK.to_string();
    }
    if event.timestamp_unix <= 0 {
        event.timestamp_unix = unix_now_secs();
    }

    let cap = store.max_events.clamp(16, MAX_STATS_EVENTS);
    store.max_events = cap;
    store.events.push(event);
    if store.events.len() > cap {
        let excess = store.events.len() - cap;
        store.events.drain(0..excess);
    }
}

/// Record a single DNS block event into tmpfs (`rt_dir/dns-block-stats.json`) with bounded retention.
#[allow(dead_code)]
pub fn ingest_dns_block_event_in(rt_dir: &Path, event: DnsBlockEvent) -> anyhow::Result<bool> {
    let _guard = stats_lock()
        .lock()
        .map_err(|_| anyhow::anyhow!("stats lock poisoned"))?;
    let mut store = load_stats_store_locked(rt_dir);
    push_event_into_store(&mut store, event);
    save_stats_store_locked(rt_dir, &store)
}

/// Record a DNS block event into the active runtime tmpfs store (`runtime_state_dir()`).
#[allow(dead_code)]
pub fn ingest_dns_block_event(event: DnsBlockEvent) -> anyhow::Result<bool> {
    ingest_dns_block_event_in(&runtime_state_dir(), event)
}

/// Record a batch of DNS block events under a single lock/write cycle.
pub fn ingest_dns_block_events_in(
    rt_dir: &Path,
    events: Vec<DnsBlockEvent>,
) -> anyhow::Result<usize> {
    if events.is_empty() {
        return Ok(0);
    }
    let _guard = stats_lock()
        .lock()
        .map_err(|_| anyhow::anyhow!("stats lock poisoned"))?;
    let mut store = load_stats_store_locked(rt_dir);
    let count = events.len();
    for ev in events {
        push_event_into_store(&mut store, ev);
    }
    let _ = save_stats_store_locked(rt_dir, &store)?;
    Ok(count)
}

fn period_cutoff(period: &str, now_unix: i64) -> anyhow::Result<(&'static str, i64)> {
    match period.trim().to_ascii_lowercase().as_str() {
        "1h" => Ok(("1h", now_unix.saturating_sub(3_600))),
        "" | "24h" => Ok(("24h", now_unix.saturating_sub(86_400))),
        "7d" => Ok(("7d", now_unix.saturating_sub(7 * 86_400))),
        "all" => Ok(("all", 0)),
        other => Err(anyhow::anyhow!(
            "unsupported period '{other}'; expected one of 1h, 24h, 7d, all"
        )),
    }
}

pub fn build_client_name_map(
    store: &RouterStoreData,
    lan_devices: &[crate::sys_info::LanDevice],
) -> HashMap<String, String> {
    let mut map = HashMap::new();
    for dev in lan_devices {
        let ip = dev.ip.trim();
        if ip.is_empty() {
            continue;
        }
        let label = [
            dev.custom_name.as_str(),
            dev.hostname.as_str(),
            dev.vendor.as_str(),
        ]
        .into_iter()
        .map(str::trim)
        .find(|s| !s.is_empty());
        if let Some(name) = label {
            map.insert(ip.to_string(), name.to_string());
        }
    }
    for meta in store.device_registry.values() {
        let ip = meta.ip.trim();
        let cname = meta.custom_name.trim();
        if !ip.is_empty() && !cname.is_empty() {
            map.entry(ip.to_string())
                .or_insert_with(|| cname.to_string());
        }
    }
    map
}

/// Query aggregated per-client and per-domain DNS block statistics for `period` (`1h`, `24h`, `7d`, `all`).
pub fn query_dns_block_stats_in(
    rt_dir: &Path,
    period: &str,
    now_unix: i64,
    client_names: &HashMap<String, String>,
) -> anyhow::Result<DnsBlockStatsResponse> {
    let (norm_period, cutoff) = period_cutoff(period, now_unix)?;
    let events = {
        let _guard = stats_lock()
            .lock()
            .map_err(|_| anyhow::anyhow!("stats lock poisoned"))?;
        load_stats_store_locked(rt_dir).events
    };

    let mut filtered: Vec<DnsBlockEvent> = events
        .into_iter()
        .filter(|e| e.timestamp_unix >= cutoff)
        .collect();

    for ev in &mut filtered {
        if ev.client_name.is_empty()
            && let Some(name) = client_names.get(&ev.client_ip)
        {
            ev.client_name = name.clone();
        }
    }

    struct DomainHitAgg {
        count: u64,
        matched_rule: String,
        list_source: String,
        last_seen: i64,
    }
    struct ClientAgg {
        client_name: String,
        blocked_count: u64,
        last_seen: i64,
        domains: HashMap<String, DomainHitAgg>,
    }
    fn record_domain_hit(map: &mut HashMap<String, DomainHitAgg>, ev: &DnsBlockEvent) {
        let entry = map
            .entry(ev.domain.clone())
            .or_insert_with(|| DomainHitAgg {
                count: 0,
                matched_rule: ev.matched_rule.clone(),
                list_source: ev.list_source.clone(),
                last_seen: ev.timestamp_unix,
            });
        entry.count += 1;
        if ev.timestamp_unix >= entry.last_seen {
            entry.matched_rule = ev.matched_rule.clone();
            entry.list_source = ev.list_source.clone();
            entry.last_seen = ev.timestamp_unix;
        }
    }

    let total_blocked = filtered.len() as u64;
    let mut global_domains: HashMap<String, DomainHitAgg> = HashMap::new();
    let mut global_rules: HashMap<(String, String), u64> = HashMap::new();
    let mut global_lists: HashMap<String, u64> = HashMap::new();
    let mut per_client: HashMap<String, ClientAgg> = HashMap::new();

    for ev in &filtered {
        record_domain_hit(&mut global_domains, ev);

        *global_rules
            .entry((ev.matched_rule.clone(), ev.list_source.clone()))
            .or_insert(0) += 1;
        *global_lists.entry(ev.list_source.clone()).or_insert(0) += 1;

        let cl = per_client
            .entry(ev.client_ip.clone())
            .or_insert_with(|| ClientAgg {
                client_name: ev.client_name.clone(),
                blocked_count: 0,
                last_seen: ev.timestamp_unix,
                domains: HashMap::new(),
            });
        if cl.client_name.is_empty() && !ev.client_name.is_empty() {
            cl.client_name = ev.client_name.clone();
        }
        cl.blocked_count += 1;
        if ev.timestamp_unix > cl.last_seen {
            cl.last_seen = ev.timestamp_unix;
        }
        record_domain_hit(&mut cl.domains, ev);
    }

    fn collect_sorted_domains(
        map: HashMap<String, DomainHitAgg>,
        limit: usize,
    ) -> Vec<DomainBlockStats> {
        let mut list: Vec<DomainBlockStats> = map
            .into_iter()
            .map(|(domain, d)| DomainBlockStats {
                domain,
                count: d.count,
                matched_rule: d.matched_rule,
                list_source: d.list_source,
                last_seen: d.last_seen,
            })
            .collect();
        list.sort_by(|a, b| b.count.cmp(&a.count).then(a.domain.cmp(&b.domain)));
        list.truncate(limit);
        list
    }

    let unique_clients = per_client.len();
    let unique_domains = global_domains.len();

    let mut clients: Vec<ClientBlockStats> = per_client
        .into_iter()
        .map(|(client_ip, agg)| {
            let dom_len = agg.domains.len();
            let top_domains = collect_sorted_domains(agg.domains, 20);
            ClientBlockStats {
                client_ip,
                client_name: agg.client_name,
                blocked_count: agg.blocked_count,
                unique_domains: dom_len,
                last_seen: agg.last_seen,
                top_domains,
            }
        })
        .collect();
    clients.sort_by(|a, b| {
        b.blocked_count
            .cmp(&a.blocked_count)
            .then(a.client_ip.cmp(&b.client_ip))
    });

    let top_domains = collect_sorted_domains(global_domains, 50);

    let mut top_rules: Vec<RuleBlockStats> = global_rules
        .into_iter()
        .map(|((matched_rule, list_source), count)| RuleBlockStats {
            matched_rule,
            list_source,
            count,
        })
        .collect();
    top_rules.sort_by(|a, b| {
        b.count
            .cmp(&a.count)
            .then(a.matched_rule.cmp(&b.matched_rule))
    });
    top_rules.truncate(50);

    let mut top_lists: Vec<ListBlockStats> = global_lists
        .into_iter()
        .map(|(list_source, count)| ListBlockStats { list_source, count })
        .collect();
    top_lists.sort_by(|a, b| {
        b.count
            .cmp(&a.count)
            .then(a.list_source.cmp(&b.list_source))
    });

    filtered.sort_by_key(|a| std::cmp::Reverse(a.timestamp_unix));
    filtered.truncate(MAX_RECENT_EVENTS_RETURNED);

    Ok(DnsBlockStatsResponse {
        ok: true,
        period: norm_period.to_string(),
        generated_at: now_unix,
        total_blocked,
        unique_clients,
        unique_domains,
        clients,
        top_domains,
        top_rules,
        top_lists,
        recent_events: filtered,
    })
}

#[allow(dead_code)]
pub fn query_dns_block_stats(period: &str) -> anyhow::Result<DnsBlockStatsResponse> {
    query_dns_block_stats_in(
        &runtime_state_dir(),
        period,
        unix_now_secs(),
        &HashMap::new(),
    )
}

fn mark_dedup_key(state: &mut TelemetrySyncState, key: String) -> bool {
    if !state.seen_keys.insert(key.clone()) {
        return false;
    }
    state.seen_order.push_back(key);
    while state.seen_order.len() > MAX_INGESTED_LOG_KEYS {
        if let Some(old) = state.seen_order.pop_front() {
            state.seen_keys.remove(&old);
        }
    }
    true
}

fn extract_ip_token(raw: &str) -> Option<String> {
    let cleaned = raw
        .trim()
        .trim_matches(|c: char| matches!(c, '(' | ')' | '[' | ']' | ',' | ';' | '"'));
    if cleaned.is_empty() {
        return None;
    }
    // Strip optional `:port` on IPv4 or `[ipv6]:port`
    if let Ok(ip) = cleaned.parse::<IpAddr>() {
        return Some(ip.to_string());
    }
    if let Some((host_part, port_part)) = cleaned.rsplit_once(':')
        && port_part.parse::<u16>().is_ok()
    {
        let unbracket = host_part.trim_matches(|c| c == '[' || c == ']');
        if let Ok(ip) = unbracket.parse::<IpAddr>() {
            return Some(ip.to_string());
        }
    }
    if valid_ip_with_zone(cleaned) {
        return Some(cleaned.to_string());
    }
    None
}

fn extract_domain_from_log_tokens(line: &str) -> Option<String> {
    for tok in line.split_whitespace() {
        let stripped = tok
            .split('=')
            .next_back()
            .unwrap_or(tok)
            .trim_matches(|c: char| matches!(c, '(' | ')' | '[' | ']' | ',' | ';' | '"' | '\''));
        let host = stripped
            .split_once(':')
            .filter(|(_, p)| p.parse::<u16>().is_ok())
            .map_or(stripped, |(h, _)| h);
        if let Some(dom) = normalize_rule_domain(host) {
            return Some(dom);
        }
    }
    None
}

fn extract_client_ip_from_log(line: &str) -> Option<String> {
    // Prefer explicit `client=<ip>`, `src=<ip>`, `from <ip>` first.
    let tokens: Vec<&str> = line.split_whitespace().collect();
    for (idx, tok) in tokens.iter().enumerate() {
        let lower = tok.to_ascii_lowercase();
        for key in ["client=", "client_ip=", "src=", "src_ip=", "source_ip="] {
            if let Some(rest) = lower.strip_prefix(key)
                && let Some(ip) = extract_ip_token(rest)
            {
                return Some(ip);
            }
        }
        if matches!(lower.as_str(), "from" | "client")
            && let Some(next) = tokens.get(idx + 1)
            && let Some(ip) = extract_ip_token(next)
        {
            return Some(ip);
        }
    }
    for tok in tokens {
        if let Some(ip) = extract_ip_token(tok) {
            return Some(ip);
        }
    }
    None
}

fn parse_text_log_dns_block(
    line: &str,
    now_unix: i64,
    store: &RouterStoreData,
    index: Option<&CompiledAdguardIndex>,
) -> Option<(String, DnsBlockEvent)> {
    let lower = line.to_ascii_lowercase();
    let has_dns_block_marker = (lower.contains("adguard") && !lower.contains("adguard-allow"))
        || (lower.contains("dns")
            && (lower.contains("nxdomain")
                || lower.contains("predefined nxdomain")
                || lower.contains("blocked")
                || lower.contains("rejected")
                || lower.contains("hosts")));
    if !has_dns_block_marker {
        return None;
    }

    let domain = extract_domain_from_log_tokens(line)?;
    if domain == "use-application-dns.net" {
        return None;
    }

    let client_ip = extract_client_ip_from_log(line).unwrap_or_else(|| "router".to_string());
    if !lower.contains("adguard") {
        // Require matching an active block rule unless the log explicitly carries an `adguard` tag.
        resolve_rule_for_domain(&domain, &client_ip, store, index)
            .filter(|m| m.kind == Some(RuleKind::Block))?;
    }

    let rule_hint = line
        .split_whitespace()
        .find_map(|tok| {
            tok.strip_prefix("rule=")
                .or_else(|| tok.strip_prefix("rule_set="))
        })
        .map(|s| s.trim_matches(|c| c == ',' || c == ')'))
        .unwrap_or("");
    let (matched_rule, list_source) =
        resolve_block_attribution(&domain, &client_ip, rule_hint, "", store, index);

    let dedup = format!("log:{line}");
    Some((
        dedup,
        DnsBlockEvent {
            timestamp_unix: now_unix,
            client_ip,
            client_name: String::new(),
            domain,
            matched_rule,
            list_source,
        },
    ))
}

fn parse_json_entry_dns_block(
    entry: &Value,
    prefix: &str,
    now_unix: i64,
    store: &RouterStoreData,
    index: Option<&CompiledAdguardIndex>,
) -> Option<(String, DnsBlockEvent)> {
    if let Some(s) = entry.as_str() {
        return parse_text_log_dns_block(s, now_unix, store, index);
    }
    let obj = entry.as_object()?;
    let msg = obj
        .get("msg")
        .or_else(|| obj.get("message"))
        .and_then(Value::as_str)
        .unwrap_or("");
    let rcode = obj.get("rcode").and_then(Value::as_str).unwrap_or("");
    let rule = obj
        .get("rule")
        .or_else(|| obj.get("rule_set"))
        .or_else(|| obj.get("rulePayload"))
        .or_else(|| obj.get("outbound"))
        .and_then(Value::as_str)
        .unwrap_or("");
    let status = obj
        .get("status")
        .or_else(|| obj.get("action"))
        .or_else(|| obj.get("reason"))
        .and_then(Value::as_str)
        .unwrap_or("");
    let combined_lower = format!("{msg} {rcode} {rule} {status}").to_ascii_lowercase();

    let explicit_adguard = (rule.to_ascii_lowercase().contains("adguard")
        || combined_lower.contains("adguard-block"))
        && !rule.to_ascii_lowercase().contains("adguard-allow");
    let is_dns_nxdomain = rcode.eq_ignore_ascii_case("nxdomain")
        || (combined_lower.contains("nxdomain")
            && (combined_lower.contains("dns") || combined_lower.contains("predefined")));
    let is_dns_blocked = combined_lower.contains("dns")
        && (combined_lower.contains("blocked") || combined_lower.contains("rejected"));

    if !explicit_adguard && !is_dns_nxdomain && !is_dns_blocked {
        if !msg.is_empty() {
            return parse_text_log_dns_block(msg, now_unix, store, index);
        }
        return None;
    }

    let raw_domain = obj
        .get("domain")
        .or_else(|| obj.get("host"))
        .or_else(|| entry.pointer("/metadata/host"))
        .or_else(|| entry.pointer("/metadata/sniffHost"))
        .or_else(|| obj.get("destination"))
        .and_then(Value::as_str)
        .unwrap_or("");
    let domain =
        normalize_rule_domain(raw_domain).or_else(|| extract_domain_from_log_tokens(msg))?;
    if domain == "use-application-dns.net" {
        return None;
    }

    let raw_client = obj
        .get("client_ip")
        .or_else(|| obj.get("src_ip"))
        .or_else(|| obj.get("source_ip"))
        .or_else(|| obj.get("client"))
        .or_else(|| entry.pointer("/metadata/sourceIP"))
        .and_then(Value::as_str)
        .unwrap_or("");
    let client_ip = extract_ip_token(raw_client)
        .or_else(|| extract_client_ip_from_log(msg))
        .unwrap_or_else(|| "router".to_string());

    if !explicit_adguard {
        resolve_rule_for_domain(&domain, &client_ip, store, index)
            .filter(|m| m.kind == Some(RuleKind::Block))?;
    }

    let ts = obj
        .get("ts")
        .or_else(|| obj.get("timestamp"))
        .or_else(|| obj.get("timestamp_unix"))
        .and_then(Value::as_i64)
        .filter(|t| *t > 1_000_000_000)
        .unwrap_or(now_unix);

    let (matched_rule, list_source) =
        resolve_block_attribution(&domain, &client_ip, rule, "", store, index);
    let entry_id = obj
        .get("id")
        .or_else(|| obj.get("seq"))
        .and_then(|v| {
            v.as_str()
                .map(str::to_string)
                .or_else(|| v.as_u64().map(|n| n.to_string()))
        })
        .unwrap_or_else(|| format!("{ts}|{client_ip}|{domain}|{rule}|{msg}"));

    Some((
        format!("{prefix}:{entry_id}"),
        DnsBlockEvent {
            timestamp_unix: ts,
            client_ip,
            client_name: String::new(),
            domain,
            matched_rule,
            list_source,
        },
    ))
}

/// Extract new DNS block events from core logs, `/tachyon/logs/recent`, `/tachyon/flight`,
/// and `/connections`, deduplicating against already-seen log/record keys.
pub fn ingest_core_telemetry_payloads_in(
    rt_dir: &Path,
    store: &RouterStoreData,
    live_recent_logs: &[String],
    logs_json: Option<&Value>,
    flight_json: Option<&Value>,
    conns_json: Option<&Value>,
    now_unix: i64,
) -> anyhow::Result<usize> {
    let index = load_compiled_index_in(rt_dir);
    let mut candidates: Vec<(String, DnsBlockEvent)> = Vec::new();

    for line in live_recent_logs {
        if let Some(item) = parse_text_log_dns_block(line, now_unix, store, index.as_ref()) {
            candidates.push(item);
        }
    }

    if let Some(arr) = logs_json
        .and_then(|v| v.get("entries"))
        .and_then(Value::as_array)
    {
        for entry in arr {
            if let Some(item) =
                parse_json_entry_dns_block(entry, "corelog", now_unix, store, index.as_ref())
            {
                candidates.push(item);
            }
        }
    }

    if let Some(arr) = flight_json
        .and_then(|v| v.get("records").or_else(|| v.get("entries")))
        .and_then(Value::as_array)
    {
        for entry in arr {
            if let Some(item) =
                parse_json_entry_dns_block(entry, "flight", now_unix, store, index.as_ref())
            {
                candidates.push(item);
            }
        }
    }

    if let Some(arr) = conns_json
        .and_then(|v| v.get("connections"))
        .and_then(Value::as_array)
    {
        for entry in arr {
            if let Some(item) =
                parse_json_entry_dns_block(entry, "conn", now_unix, store, index.as_ref())
            {
                candidates.push(item);
            }
        }
    }

    if candidates.is_empty() {
        return Ok(0);
    }

    let mut fresh = Vec::new();
    {
        let mut sync = telemetry_sync_state()
            .lock()
            .map_err(|_| anyhow::anyhow!("telemetry sync lock poisoned"))?;
        for (key, ev) in candidates {
            if mark_dedup_key(&mut sync, key) {
                fresh.push(ev);
            }
        }
    }

    ingest_dns_block_events_in(rt_dir, fresh)
}

/// Poll `tachyon-core` logs/flight/connections at most once every `min_interval_secs`
/// and ingest any newly observed DNS block events into tmpfs.
pub async fn sync_telemetry_from_core_if_needed(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    min_interval_secs: i64,
) {
    let now = unix_now_secs();
    {
        let Ok(mut sync) = telemetry_sync_state().lock() else {
            return;
        };
        if min_interval_secs > 0 && now.saturating_sub(sync.last_poll_secs) < min_interval_secs {
            return;
        }
        sync.last_poll_secs = now;
    }

    let (core_running, live_logs) = {
        let live = state.live.read().await;
        (live.core_running, live.recent_logs.clone())
    };
    let store = { state.data.read().await.clone() };

    let (logs_val, flight_val, conns_val) = if core_running {
        let (l, f, c) = tokio::join!(
            core.get_core_recent_logs("info", 120),
            core.get_core_flight_recorder(),
            core.clash_request("GET", "/connections", None),
        );
        (l.ok(), Some(f), c.ok())
    } else {
        (None, None, None)
    };

    let _ = ingest_core_telemetry_payloads_in(
        &runtime_state_dir(),
        &store,
        &live_logs,
        logs_val.as_ref(),
        flight_val.as_ref(),
        conns_val.as_ref(),
        now,
    );
}

pub async fn query_dns_block_stats_for_state(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    period: &str,
) -> anyhow::Result<DnsBlockStatsResponse> {
    sync_telemetry_from_core_if_needed(state, core, 2).await;
    let store = { state.data.read().await.clone() };
    let lan_devices = { state.live.read().await.lan_devices.clone() };
    let names = build_client_name_map(&store, &lan_devices);
    query_dns_block_stats_in(&runtime_state_dir(), period, unix_now_secs(), &names)
}

fn read_last_update_timestamp_in(rt_dir: &Path) -> i64 {
    let path = rt_dir.join(HOSTS_LIST_STATUS_FILE);
    let Ok(raw) = std::fs::read_to_string(path) else {
        return 0;
    };
    serde_json::from_str::<Value>(&raw)
        .ok()
        .and_then(|v| v.get("updated_at").and_then(Value::as_i64))
        .unwrap_or(0)
}

/// Spawn background periodic updater for configured hosts/AdGuard lists and continuous
/// DNS block telemetry sync from `tachyon-core`.
pub fn spawn_adguard_hosts_loop(state: Arc<AppState>, core: Arc<CoreManager>) {
    tokio::spawn(async move {
        // Short initial grace delay so core startup and interface bring-up finish first.
        tokio::time::sleep(std::time::Duration::from_secs(10)).await;
        loop {
            let store = { state.data.read().await.clone() };
            let urls = collect_active_hosts_list_urls(&store);
            let rt_dir = runtime_state_dir();

            if !urls.is_empty()
                && let Some(interval_secs) = auto_update_schedule(&store)
            {
                let last_ts = read_last_update_timestamp_in(&rt_dir);
                let now = unix_now_secs();
                if last_ts <= 0 || now.saturating_sub(last_ts) >= interval_secs as i64 {
                    let _ = update_hosts_lists_in(&rt_dir, &state, &core, true).await;
                }
            }

            sync_telemetry_from_core_if_needed(&state, &core, 15).await;
            tokio::time::sleep(std::time::Duration::from_secs(20)).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_rt_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "tachyon-adguard-test-{}-{}-{}",
            name,
            std::process::id(),
            unix_now_secs()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn parses_hosts_adguard_exceptions_modifiers_and_ignores_unsupported() {
        let raw = "\
# Hosts file header
127.0.0.1 localhost
::1 ip6-localhost
0.0.0.0 ads.example.com tracking.example.com # inline comment
192.168.1.50 nas.lan
printer.lan 192.168.1.60

! AdGuard Home filter header
[Adblock Plus 2.0]
example.com##.ad-banner
example.com#@#.ad-banner
example.com#$#div { display: none; }
example.com#%#//scriptlet('noop')

||adnetwork.org^
||priority.adnetwork.org^$important
@@||safe.adnetwork.org^
@@||critical.adnetwork.org^$important
|exact-only.example.net^
*.wildcard-sub.example.net^
||v6-only.example.org^$dnstype=AAAA
||client-only.example.org^$client=192.168.1.50|10.0.0.0/8
||rewritten.lan^$dnsrewrite=192.168.1.77
||blocked-rewrite.org^$dnsrewrite=NXDOMAIN

! Unsupported rules must be ignored safely
||cdn.example.com^$third-party,script
||bad.example.com^$badfilter
||example.com/ads.js
/ads-[0-9]+\\.js/
";
        let parsed = parse_list_content(raw, "https://example.org/list.txt");

        assert_eq!(parsed.detected_format, "mixed");
        assert_eq!(
            parsed.static_hosts.get("nas.lan"),
            Some(&vec!["192.168.1.50".to_string()])
        );
        assert_eq!(
            parsed.static_hosts.get("printer.lan"),
            Some(&vec!["192.168.1.60".to_string()])
        );
        assert_eq!(
            parsed.static_hosts.get("rewritten.lan"),
            Some(&vec!["192.168.1.77".to_string()])
        );

        assert!(parsed.rules.iter().any(|r| {
            r.kind == RuleKind::Block
                && r.match_kind == MatchKind::Exact
                && r.domain == "ads.example.com"
        }));
        assert!(parsed.rules.iter().any(|r| {
            r.kind == RuleKind::Block
                && r.match_kind == MatchKind::Exact
                && r.domain == "tracking.example.com"
        }));
        assert!(!parsed.rules.iter().any(|r| r.domain == "localhost"));
        assert!(!parsed.rules.iter().any(|r| r.domain == "ip6-localhost"));
        assert!(!parsed.rules.iter().any(|r| r.domain == "cdn.example.com"));
        assert!(!parsed.rules.iter().any(|r| r.domain == "bad.example.com"));
        assert!(!parsed.rules.iter().any(|r| r.domain == "example.com"));

        assert!(parsed.rules.iter().any(|r| {
            r.kind == RuleKind::Block
                && !r.important
                && r.match_kind == MatchKind::Suffix
                && r.domain == "adnetwork.org"
        }));
        assert!(parsed.rules.iter().any(|r| {
            r.kind == RuleKind::Block && r.important && r.domain == "priority.adnetwork.org"
        }));
        assert!(parsed.rules.iter().any(|r| {
            r.kind == RuleKind::Allow
                && !r.important
                && r.match_kind == MatchKind::Suffix
                && r.domain == "safe.adnetwork.org"
        }));
        assert!(parsed.rules.iter().any(|r| {
            r.kind == RuleKind::Allow && r.important && r.domain == "critical.adnetwork.org"
        }));
        assert!(parsed.rules.iter().any(|r| {
            r.kind == RuleKind::Block
                && r.match_kind == MatchKind::Exact
                && r.domain == "exact-only.example.net"
        }));
        assert!(parsed.rules.iter().any(|r| {
            r.kind == RuleKind::Block
                && r.match_kind == MatchKind::Suffix
                && r.domain == "wildcard-sub.example.net"
        }));
        assert!(parsed.rules.iter().any(|r| {
            r.domain == "v6-only.example.org" && r.query_types == vec!["AAAA".to_string()]
        }));
        assert!(parsed.rules.iter().any(|r| {
            r.domain == "client-only.example.org"
                && r.client_cidrs == vec!["10.0.0.0/8".to_string(), "192.168.1.50/32".to_string()]
        }));
        assert!(
            parsed
                .rules
                .iter()
                .any(|r| { r.kind == RuleKind::Block && r.domain == "blocked-rewrite.org" })
        );
    }

    #[test]
    fn cross_list_exception_overrides_block_and_unchanged_compilation_reports_false() {
        let rt_dir = temp_rt_dir("compile");
        let list_a = (
            "https://list-a.invalid/ads.txt".to_string(),
            "||tracker.example.org^\n0.0.0.0 exact.example.org\n||forced.example.org^$important\n"
                .to_string(),
            true,
            String::new(),
        );
        let list_b = (
            "https://list-b.invalid/allow.txt".to_string(),
            "@@||tracker.example.org^\n@@||forced.example.org^\n@@||forced-allow.example.org^$important\n||forced-allow.example.org^$important\n"
                .to_string(),
            true,
            String::new(),
        );

        let (idx1, changed1) = compile_and_store_remote_lists_in(
            &rt_dir,
            &[list_a.clone(), list_b.clone()],
            1_700_000_000,
        )
        .unwrap();
        assert!(changed1, "first compile must mark tmpfs rulesets changed");
        assert!(ruleset_file_has_entries(
            &rt_dir.join(format!("{TAG_BLOCK}.json"))
        ));
        assert!(ruleset_file_has_entries(
            &rt_dir.join(format!("{TAG_ALLOW}.json"))
        ));
        assert!(ruleset_file_has_entries(
            &rt_dir.join(format!("{TAG_BLOCK_IMPORTANT}.json"))
        ));
        assert!(ruleset_file_has_entries(
            &rt_dir.join(format!("{TAG_ALLOW_IMPORTANT}.json"))
        ));

        // Recompiling semantically identical lists (even with extra comment lines) must NOT trigger reload.
        let list_a_comment = (
            list_a.0.clone(),
            format!("! Updated timestamp 2026-11-21\n{}", list_a.1),
            true,
            String::new(),
        );
        let (idx2, changed2) =
            compile_and_store_remote_lists_in(&rt_dir, &[list_a_comment, list_b], 1_700_003_600)
                .unwrap();
        assert!(!changed2, "comment-only change must not mark rules changed");
        assert_eq!(idx1.compiled_digest, idx2.compiled_digest);

        let store = RouterStoreData::default();
        // Cross-list exception overrides normal block on subdomain and domain.
        let m1 = resolve_rule_for_domain(
            "sub.tracker.example.org",
            "192.168.1.50",
            &store,
            Some(&idx2),
        )
        .unwrap();
        assert_eq!(m1.kind, Some(RuleKind::Allow));
        assert_eq!(m1.list_source, "https://list-b.invalid/allow.txt");

        // `$important` block overrides normal `@@` exception.
        let m2 = resolve_rule_for_domain(
            "sub.forced.example.org",
            "192.168.1.50",
            &store,
            Some(&idx2),
        )
        .unwrap();
        assert_eq!(m2.kind, Some(RuleKind::Block));

        // `$important` exception overrides `$important` block.
        let m3 = resolve_rule_for_domain(
            "forced-allow.example.org",
            "192.168.1.50",
            &store,
            Some(&idx2),
        )
        .unwrap();
        assert_eq!(m3.kind, Some(RuleKind::Allow));

        let _ = std::fs::remove_dir_all(&rt_dir);
    }

    #[test]
    fn stats_ring_caps_events_and_filters_by_period_and_client() {
        let rt_dir = temp_rt_dir("stats");
        let now = 1_700_100_000i64;
        let events = vec![
            DnsBlockEvent {
                timestamp_unix: now - 10 * 86_400,
                client_ip: "192.168.1.20".into(),
                client_name: String::new(),
                domain: "old-ad.example.org".into(),
                matched_rule: "||old-ad.example.org^".into(),
                list_source: "https://list-a.invalid/ads.txt".into(),
            },
            DnsBlockEvent {
                timestamp_unix: now - 2 * 86_400,
                client_ip: "192.168.1.20".into(),
                client_name: String::new(),
                domain: "week-ad.example.org".into(),
                matched_rule: "||week-ad.example.org^".into(),
                list_source: "https://list-a.invalid/ads.txt".into(),
            },
            DnsBlockEvent {
                timestamp_unix: now - 1_800,
                client_ip: "192.168.1.50".into(),
                client_name: String::new(),
                domain: "recent-ad.example.org".into(),
                matched_rule: "||recent-ad.example.org^".into(),
                list_source: "https://list-b.invalid/ads.txt".into(),
            },
            DnsBlockEvent {
                timestamp_unix: now - 300,
                client_ip: "192.168.1.50".into(),
                client_name: String::new(),
                domain: "recent-ad.example.org".into(),
                matched_rule: "||recent-ad.example.org^".into(),
                list_source: "https://list-b.invalid/ads.txt".into(),
            },
        ];
        ingest_dns_block_events_in(&rt_dir, events).unwrap();

        let mut names = HashMap::new();
        names.insert("192.168.1.50".to_string(), "workstation".to_string());

        let r_1h = query_dns_block_stats_in(&rt_dir, "1h", now, &names).unwrap();
        assert_eq!(r_1h.total_blocked, 2);
        assert_eq!(r_1h.unique_clients, 1);
        assert_eq!(r_1h.clients[0].client_ip, "192.168.1.50");
        assert_eq!(r_1h.clients[0].client_name, "workstation");
        assert_eq!(r_1h.clients[0].blocked_count, 2);
        assert_eq!(r_1h.top_domains[0].matched_rule, "||recent-ad.example.org^");

        let r_7d = query_dns_block_stats_in(&rt_dir, "7d", now, &names).unwrap();
        assert_eq!(r_7d.total_blocked, 3);
        assert_eq!(r_7d.unique_clients, 2);

        let r_all = query_dns_block_stats_in(&rt_dir, "all", now, &names).unwrap();
        assert_eq!(r_all.total_blocked, 4);
        assert!(query_dns_block_stats_in(&rt_dir, "99d", now, &names).is_err());

        // Test bounded retention eviction via a batch larger than MAX_STATS_EVENTS.
        let extra: Vec<DnsBlockEvent> = (0..MAX_STATS_EVENTS)
            .map(|i| DnsBlockEvent {
                timestamp_unix: now + i as i64,
                client_ip: "192.168.1.99".into(),
                client_name: String::new(),
                domain: format!("flood-{i}.example.org"),
                matched_rule: "||example.org^".into(),
                list_source: "inline:test".into(),
            })
            .collect();
        ingest_dns_block_events_in(&rt_dir, extra).unwrap();
        let r_capped = query_dns_block_stats_in(&rt_dir, "all", now + 10_000, &names).unwrap();
        assert_eq!(r_capped.total_blocked as usize, MAX_STATS_EVENTS);

        let _ = std::fs::remove_dir_all(&rt_dir);
    }

    #[test]
    fn ingests_core_logs_and_flight_and_deduplicates_identical_polls() {
        let rt_dir = temp_rt_dir("ingest");
        let list = (
            "https://ads.invalid/filter.txt".to_string(),
            "||telemetry.example.net^\n0.0.0.0 metrics.example.org\n".to_string(),
            true,
            String::new(),
        );
        let now = 1_700_200_000i64;
        compile_and_store_remote_lists_in(&rt_dir, &[list], now).unwrap();

        let store = RouterStoreData::default();
        let live_logs = vec![
            "[dns] client=192.168.1.42 domain=a.telemetry.example.net rcode=NXDOMAIN rule=adguard-block"
                .to_string(),
            "[dns] client=192.168.1.43 domain=allowlisted.example.com rcode=NOERROR".to_string(),
        ];
        let logs_json = json!({
            "entries": [
                {
                    "id": "log-101",
                    "ts": now - 5,
                    "msg": "dns blocked",
                    "domain": "metrics.example.org",
                    "client_ip": "192.168.1.44",
                    "rcode": "NXDOMAIN",
                    "rule": "adguard-block"
                }
            ]
        });
        let flight_json = json!({
            "records": [
                {
                    "id": "fl-202",
                    "ts": now - 2,
                    "host": "sub.telemetry.example.net",
                    "client": "192.168.1.42",
                    "status": "blocked",
                    "rule": "adguard-block"
                }
            ]
        });

        let added1 = ingest_core_telemetry_payloads_in(
            &rt_dir,
            &store,
            &live_logs,
            Some(&logs_json),
            Some(&flight_json),
            None,
            now,
        )
        .unwrap();
        assert_eq!(added1, 3);

        // Polling the same snapshots again must not double count.
        let added2 = ingest_core_telemetry_payloads_in(
            &rt_dir,
            &store,
            &live_logs,
            Some(&logs_json),
            Some(&flight_json),
            None,
            now + 5,
        )
        .unwrap();
        assert_eq!(added2, 0);

        let stats = query_dns_block_stats_in(&rt_dir, "1h", now + 5, &HashMap::new()).unwrap();
        assert_eq!(stats.total_blocked, 3);
        assert_eq!(stats.clients[0].client_ip, "192.168.1.42");
        assert_eq!(stats.clients[0].blocked_count, 2);
        assert!(
            stats
                .top_rules
                .iter()
                .any(|r| r.matched_rule == "||telemetry.example.net^"
                    && r.list_source == "https://ads.invalid/filter.txt"
                    && r.count == 2)
        );
        assert!(
            stats
                .top_rules
                .iter()
                .any(|r| r.matched_rule == "0.0.0.0 metrics.example.org"
                    && r.list_source == "https://ads.invalid/filter.txt"
                    && r.count == 1)
        );

        let _ = std::fs::remove_dir_all(&rt_dir);
    }

    #[test]
    fn collects_urls_excluding_disabled_and_parses_intervals() {
        let mut store = RouterStoreData::default();
        store.settings.hosts_list_urls = vec!["https://g.invalid/a.txt".into()];
        let mut sec1 = crate::store::RoutingSection {
            id: "adguard".into(),
            label: "AdGuard".into(),
            enabled: true,
            hosts_list_urls: vec![
                "https://s.invalid/active.txt".into(),
                "https://s.invalid/off.txt".into(),
                "https://g.invalid/a.txt".into(),
            ],
            hosts_list_disabled: vec!["https://s.invalid/off.txt".into()],
            ..Default::default()
        };
        let sec2 = crate::store::RoutingSection {
            id: "disabled-sec".into(),
            label: "DisabledSec".into(),
            enabled: false,
            hosts_list_urls: vec!["https://s.invalid/disabled-sec.txt".into()],
            ..Default::default()
        };
        store.sections = vec![sec1.clone(), sec2];

        let urls = collect_active_hosts_list_urls(&store);
        assert_eq!(
            urls,
            vec![
                "https://g.invalid/a.txt".to_string(),
                "https://s.invalid/active.txt".to_string(),
            ]
        );

        assert_eq!(parse_update_interval_secs("1h"), 3_600);
        assert_eq!(parse_update_interval_secs("12h"), 43_200);
        assert_eq!(parse_update_interval_secs("24h"), 86_400);
        assert_eq!(parse_update_interval_secs("7d"), 604_800);
        assert_eq!(parse_update_interval_secs("1m"), MIN_UPDATE_INTERVAL_SECS);
        sec1.hosts_list_auto_update = true;
        sec1.hosts_list_update_interval = "6h".into();
        store.sections[0] = sec1;
        assert_eq!(auto_update_schedule(&store), Some(21_600));
    }
}
