//! Transient configuration change log and instant 1-click rollback stored strictly in tmpfs.
//!
//! Records structural diffs (with secrets masked and background subscription telemetry ignored)
//! alongside the pre-change `RouterStoreData` snapshot so any recent save can be reviewed and
//! reverted without writing to NAND flash.

use std::collections::hash_map::Entry;
use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Mutex, OnceLock};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::crypto_gen;
use crate::store::{RouterStoreData, unix_now_secs};

pub const MAX_CONFIG_HISTORY_ENTRIES: usize = 20;
pub const MAX_DIFF_ENTRIES_PER_REV: usize = 120;
pub const COALESCE_WINDOW_SECS: i64 = 3;

const MAX_PREVIEW_CHARS: usize = 140;

const IGNORED_DIFF_FIELDS: &[&str] = &[
    "last_updated_unix",
    "cached_nodes",
    "sub_upload_bytes",
    "sub_download_bytes",
    "sub_total_bytes",
    "sub_expire_unix",
    "sub_last_error",
    "sub_upload",
    "sub_download",
    "sub_total",
    "sub_expire",
    "sub_title",
    "sub_announce",
    "legacy_uci_imported",
    "used_minutes_today",
];

static HISTORY_MUTEX: OnceLock<Mutex<()>> = OnceLock::new();
static REV_SEQ: AtomicU32 = AtomicU32::new(1);

fn history_lock() -> &'static Mutex<()> {
    HISTORY_MUTEX.get_or_init(|| Mutex::new(()))
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConfigDiffEntry {
    pub scope: String,
    pub target: String,
    pub field: String,
    pub kind: String,
    pub before: String,
    pub after: String,
}

fn default_revision_status() -> String {
    "checking".to_string()
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ConfigRevisionSummary {
    pub id: String,
    pub timestamp: i64,
    pub source: String,
    #[serde(default = "default_revision_status")]
    pub status: String,
    #[serde(default)]
    pub status_reason: String,
    pub added: usize,
    pub changed: usize,
    pub removed: usize,
    pub total_changes: usize,
    pub truncated: usize,
    pub changes: Vec<ConfigDiffEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConfigRevisionFile {
    pub summary: ConfigRevisionSummary,
    pub before_store: Box<RouterStoreData>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after_store: Option<Box<RouterStoreData>>,
}

#[derive(Debug, Deserialize)]
struct ConfigRevisionSummaryOnly {
    summary: ConfigRevisionSummary,
}

pub fn history_dir() -> PathBuf {
    #[cfg(target_os = "linux")]
    {
        PathBuf::from("/tmp/tachyon/config-history")
    }
    #[cfg(not(target_os = "linux"))]
    {
        std::env::temp_dir().join("tachyon-config-history")
    }
}

fn is_valid_revision_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn is_sensitive_diff_field(field: &str) -> bool {
    let k = field.trim().to_ascii_lowercase();
    k == "key"
        || k.contains("password")
        || k.contains("secret")
        || k.contains("token")
        || k.contains("private_key")
        || k.contains("preshared_key")
        || k.contains("psk")
        || k.contains("uuid")
        || k.contains("auth_key")
        || k.contains("api_key")
        || k.contains("cookie")
        || k.contains("short_id")
}

fn is_empty_json_value(v: &Value) -> bool {
    match v {
        Value::Null => true,
        Value::String(s) => s.is_empty(),
        Value::Array(a) => a.is_empty(),
        Value::Object(o) => o.is_empty(),
        _ => false,
    }
}

fn truncate_chars(input: &str, max_chars: usize) -> String {
    let mut chars = input.chars();
    let collected: String = chars.by_ref().take(max_chars).collect();
    if chars.next().is_some() {
        format!("{collected}...")
    } else {
        collected
    }
}

fn format_diff_value(field: &str, val: &Value) -> String {
    if is_sensitive_diff_field(field) {
        return if is_empty_json_value(val) {
            String::new()
        } else {
            "***".to_string()
        };
    }
    match val {
        Value::Null => String::new(),
        Value::Bool(b) => {
            if *b {
                "true".to_string()
            } else {
                "false".to_string()
            }
        }
        Value::Number(n) => n.to_string(),
        Value::String(s) => truncate_chars(s, MAX_PREVIEW_CHARS),
        Value::Array(arr) => {
            if arr.is_empty() {
                return "[]".to_string();
            }
            let preview_parts: Vec<String> = arr
                .iter()
                .take(4)
                .map(|item| match item {
                    Value::String(s) => truncate_chars(s, 40),
                    Value::Bool(b) => b.to_string(),
                    Value::Number(n) => n.to_string(),
                    Value::Null => "null".to_string(),
                    other => truncate_chars(&other.to_string(), 40),
                })
                .collect();
            let joined = preview_parts.join(", ");
            if arr.len() > 4 {
                truncate_chars(
                    &format!("[{}]: {joined}, ...", arr.len()),
                    MAX_PREVIEW_CHARS,
                )
            } else if joined.chars().count() > MAX_PREVIEW_CHARS {
                truncate_chars(&format!("[{}]: {joined}", arr.len()), MAX_PREVIEW_CHARS)
            } else {
                format!("[{joined}]")
            }
        }
        Value::Object(_) => truncate_chars(&val.to_string(), MAX_PREVIEW_CHARS),
    }
}

fn readable_item_target(obj: &Map<String, Value>, fallback_id: &str) -> String {
    for key in ["label", "name", "custom_name"] {
        if let Some(v) = obj.get(key).and_then(Value::as_str) {
            let trimmed = v.trim();
            if !trimmed.is_empty() {
                if trimmed == fallback_id || fallback_id.is_empty() {
                    return trimmed.to_string();
                }
                return format!("{trimmed} ({fallback_id})");
            }
        }
    }
    fallback_id.to_string()
}

struct DiffAccumulator {
    entries: Vec<ConfigDiffEntry>,
    added: usize,
    changed: usize,
    removed: usize,
}

impl DiffAccumulator {
    fn new() -> Self {
        Self {
            entries: Vec::new(),
            added: 0,
            changed: 0,
            removed: 0,
        }
    }

    fn push(&mut self, entry: ConfigDiffEntry) {
        match entry.kind.as_str() {
            "added" => self.added += 1,
            "removed" => self.removed += 1,
            _ => self.changed += 1,
        }
        if self.entries.len() < MAX_DIFF_ENTRIES_PER_REV {
            self.entries.push(entry);
        }
    }

    fn total_changes(&self) -> usize {
        self.added + self.changed + self.removed
    }

    fn truncated(&self) -> usize {
        self.total_changes().saturating_sub(self.entries.len())
    }
}

fn format_scalar_item(val: &Value) -> Option<String> {
    match val {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        Value::Bool(b) => Some(if *b { "true" } else { "false" }.to_string()),
        _ => None,
    }
}

fn format_delta_preview(prefix: &str, items: &[String], total_len: usize) -> String {
    let preview: Vec<String> = items
        .iter()
        .take(3)
        .map(|s| truncate_chars(s, 40))
        .collect();
    let joined = preview.join(", ");
    if items.len() > 3 {
        truncate_chars(
            &format!("{prefix} {joined}, ... (+{}; {total_len})", items.len()),
            MAX_PREVIEW_CHARS,
        )
    } else {
        truncate_chars(
            &format!("{prefix} {joined} ({total_len})"),
            MAX_PREVIEW_CHARS,
        )
    }
}

fn format_scalar_array_diff(before_arr: &[Value], after_arr: &[Value]) -> Option<(String, String)> {
    let before_items: Vec<String> = before_arr
        .iter()
        .map(format_scalar_item)
        .collect::<Option<Vec<_>>>()?;
    let after_items: Vec<String> = after_arr
        .iter()
        .map(format_scalar_item)
        .collect::<Option<Vec<_>>>()?;

    let mut after_counts: HashMap<&str, usize> = HashMap::new();
    for s in &after_items {
        *after_counts.entry(s.as_str()).or_insert(0) += 1;
    }
    let mut before_counts: HashMap<&str, usize> = HashMap::new();
    for s in &before_items {
        *before_counts.entry(s.as_str()).or_insert(0) += 1;
    }

    let mut rem_consumed = after_counts;
    let mut removed = Vec::new();
    for s in &before_items {
        if let Some(cnt) = rem_consumed.get_mut(s.as_str())
            && *cnt > 0
        {
            *cnt -= 1;
        } else {
            removed.push(s.clone());
        }
    }

    let mut add_consumed = before_counts;
    let mut added = Vec::new();
    for s in &after_items {
        if let Some(cnt) = add_consumed.get_mut(s.as_str())
            && *cnt > 0
        {
            *cnt -= 1;
        } else {
            added.push(s.clone());
        }
    }

    match (!removed.is_empty(), !added.is_empty()) {
        (false, true) => Some((
            format!("[{}]", before_items.len()),
            format_delta_preview("+", &added, after_items.len()),
        )),
        (true, false) => Some((
            format_delta_preview("-", &removed, before_items.len()),
            format!("[{}]", after_items.len()),
        )),
        (true, true) => Some((
            format_delta_preview("-", &removed, before_items.len()),
            format_delta_preview("+", &added, after_items.len()),
        )),
        (false, false) => None,
    }
}

fn diff_object_fields(
    acc: &mut DiffAccumulator,
    scope: &str,
    target: &str,
    before_obj: &Map<String, Value>,
    after_obj: &Map<String, Value>,
) {
    let mut keys: BTreeSet<&str> = BTreeSet::new();
    for k in before_obj.keys() {
        keys.insert(k.as_str());
    }
    for k in after_obj.keys() {
        keys.insert(k.as_str());
    }
    for key in keys {
        if IGNORED_DIFF_FIELDS.contains(&key) {
            continue;
        }
        let b_val = before_obj.get(key).unwrap_or(&Value::Null);
        let a_val = after_obj.get(key).unwrap_or(&Value::Null);
        if b_val == a_val {
            continue;
        }
        let (b_str, a_str) = if !is_sensitive_diff_field(key)
            && let (Value::Array(b_arr), Value::Array(a_arr)) = (b_val, a_val)
            && let Some((b_delta, a_delta)) = format_scalar_array_diff(b_arr, a_arr)
        {
            (b_delta, a_delta)
        } else {
            (format_diff_value(key, b_val), format_diff_value(key, a_val))
        };
        if b_str == a_str && is_empty_json_value(b_val) && is_empty_json_value(a_val) {
            continue;
        }
        let kind = if is_empty_json_value(b_val) && !is_empty_json_value(a_val) {
            "added"
        } else if !is_empty_json_value(b_val) && is_empty_json_value(a_val) {
            "removed"
        } else {
            "changed"
        };
        acc.push(ConfigDiffEntry {
            scope: scope.to_string(),
            target: target.to_string(),
            field: key.to_string(),
            kind: kind.to_string(),
            before: b_str,
            after: a_str,
        });
    }
}

fn diff_named_array<T: Serialize>(
    acc: &mut DiffAccumulator,
    scope: &str,
    before_items: &[T],
    after_items: &[T],
) {
    let to_map = |items: &[T]| -> (Vec<String>, HashMap<String, Map<String, Value>>) {
        let mut order = Vec::with_capacity(items.len());
        let mut by_id = HashMap::with_capacity(items.len());
        for (idx, item) in items.iter().enumerate() {
            if let Ok(Value::Object(obj)) = serde_json::to_value(item) {
                let id = obj
                    .get("id")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(str::to_string)
                    .unwrap_or_else(|| format!("#{idx}"));
                if let Entry::Vacant(entry) = by_id.entry(id) {
                    order.push(entry.key().clone());
                    entry.insert(obj);
                }
            }
        }
        (order, by_id)
    };

    let (before_order, before_map) = to_map(before_items);
    let (after_order, after_map) = to_map(after_items);

    for id in &before_order {
        let b_obj = &before_map[id];
        match after_map.get(id) {
            None => {
                let target = readable_item_target(b_obj, id);
                acc.push(ConfigDiffEntry {
                    scope: scope.to_string(),
                    target: target.clone(),
                    field: String::new(),
                    kind: "removed".to_string(),
                    before: target,
                    after: String::new(),
                });
            }
            Some(a_obj) => {
                let target = readable_item_target(a_obj, id);
                diff_object_fields(acc, scope, &target, b_obj, a_obj);
            }
        }
    }

    for id in &after_order {
        if !before_map.contains_key(id) {
            let a_obj = &after_map[id];
            let target = readable_item_target(a_obj, id);
            acc.push(ConfigDiffEntry {
                scope: scope.to_string(),
                target: target.clone(),
                field: String::new(),
                kind: "added".to_string(),
                before: String::new(),
                after: target,
            });
        }
    }
}

fn diff_singular<T: Serialize>(acc: &mut DiffAccumulator, scope: &str, before: &T, after: &T) {
    if let (Ok(Value::Object(b_obj)), Ok(Value::Object(a_obj))) =
        (serde_json::to_value(before), serde_json::to_value(after))
    {
        diff_object_fields(acc, scope, scope, &b_obj, &a_obj);
    }
}

fn diff_device_registry(
    acc: &mut DiffAccumulator,
    before: &RouterStoreData,
    after: &RouterStoreData,
) {
    let mut all_ips: BTreeSet<&str> = BTreeSet::new();
    for ip in before.device_registry.keys() {
        all_ips.insert(ip.as_str());
    }
    for ip in after.device_registry.keys() {
        all_ips.insert(ip.as_str());
    }
    for ip in all_ips {
        match (
            before.device_registry.get(ip),
            after.device_registry.get(ip),
        ) {
            (Some(b_dev), None) => {
                if let Ok(Value::Object(b_obj)) = serde_json::to_value(b_dev) {
                    let target = readable_item_target(&b_obj, ip);
                    acc.push(ConfigDiffEntry {
                        scope: "device".to_string(),
                        target: target.clone(),
                        field: String::new(),
                        kind: "removed".to_string(),
                        before: target,
                        after: String::new(),
                    });
                }
            }
            (None, Some(a_dev)) => {
                if let Ok(Value::Object(a_obj)) = serde_json::to_value(a_dev) {
                    let target = readable_item_target(&a_obj, ip);
                    acc.push(ConfigDiffEntry {
                        scope: "device".to_string(),
                        target: target.clone(),
                        field: String::new(),
                        kind: "added".to_string(),
                        before: String::new(),
                        after: target,
                    });
                }
            }
            (Some(b_dev), Some(a_dev)) => {
                if let (Ok(Value::Object(b_obj)), Ok(Value::Object(a_obj))) =
                    (serde_json::to_value(b_dev), serde_json::to_value(a_dev))
                {
                    let target = readable_item_target(&a_obj, ip);
                    diff_object_fields(acc, "device", &target, &b_obj, &a_obj);
                }
            }
            (None, None) => {}
        }
    }
}

#[inline(never)]
fn compute_store_diff_detailed(
    before: &RouterStoreData,
    after: &RouterStoreData,
) -> DiffAccumulator {
    let mut acc = DiffAccumulator::new();
    diff_singular(&mut acc, "settings", &before.settings, &after.settings);
    diff_singular(&mut acc, "telegram", &before.telegram, &after.telegram);
    diff_singular(
        &mut acc,
        "guest_mode",
        &before.guest_mode,
        &after.guest_mode,
    );
    diff_named_array(&mut acc, "section", &before.sections, &after.sections);
    diff_named_array(
        &mut acc,
        "outbound_source",
        &before.outbound_sources,
        &after.outbound_sources,
    );
    diff_named_array(
        &mut acc,
        "outbound_group",
        &before.outbound_groups,
        &after.outbound_groups,
    );
    diff_named_array(&mut acc, "condition", &before.conditions, &after.conditions);
    diff_named_array(&mut acc, "balancer", &before.balancers, &after.balancers);
    diff_named_array(&mut acc, "server", &before.servers, &after.servers);
    diff_named_array(&mut acc, "profile", &before.profiles, &after.profiles);
    diff_named_array(&mut acc, "schedule", &before.schedules, &after.schedules);
    diff_device_registry(&mut acc, before, after);
    acc
}

/// Compute structural diff across `RouterStoreData`, masking secrets and ignoring runtime telemetry.
#[allow(dead_code)]
#[inline(never)]
pub fn compute_store_diff(
    before: &RouterStoreData,
    after: &RouterStoreData,
) -> (Vec<ConfigDiffEntry>, usize) {
    let acc = compute_store_diff_detailed(before, after);
    let truncated = acc.truncated();
    (acc.entries, truncated)
}

fn read_revision_file(path: &Path) -> anyhow::Result<Box<ConfigRevisionFile>> {
    let raw = std::fs::read_to_string(path)?;
    let parsed: Box<ConfigRevisionFile> = serde_json::from_str(&raw)?;
    Ok(parsed)
}

fn read_revision_summary_only(path: &Path) -> anyhow::Result<ConfigRevisionSummary> {
    let raw = std::fs::read_to_string(path)?;
    let parsed: ConfigRevisionSummaryOnly = serde_json::from_str(&raw)?;
    Ok(parsed.summary)
}

fn write_revision_file(path: &Path, doc: &ConfigRevisionFile) -> anyhow::Result<()> {
    let bytes = serde_json::to_vec(doc)?;
    let _ = crypto_gen::write_bytes_with_mode_if_changed(path, &bytes, 0o600)?;
    Ok(())
}

fn collect_sorted_summaries_in(dir: &Path) -> Vec<ConfigRevisionSummary> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut items = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        let fallback_id = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_string();
        if !is_valid_revision_id(&fallback_id) {
            continue;
        }
        if let Ok(summary) = read_revision_summary_only(&path) {
            items.push(summary);
        }
    }
    items.sort_by(|a, b| b.timestamp.cmp(&a.timestamp).then_with(|| b.id.cmp(&a.id)));
    items
}

fn prune_old_revisions_in(dir: &Path, max_entries: usize) {
    let summaries = collect_sorted_summaries_in(dir);
    for old in summaries.into_iter().skip(max_entries) {
        if is_valid_revision_id(&old.id) {
            let _ = std::fs::remove_file(dir.join(format!("{}.json", old.id)));
        }
    }
}

/// Clone `RouterStoreData` onto the heap without transient `cached_nodes` to keep tmpfs footprint minimal.
#[inline(never)]
fn clone_store_without_cached_nodes(src: &RouterStoreData) -> Box<RouterStoreData> {
    let mut boxed = Box::new(src.clone());
    for s in &mut boxed.outbound_sources {
        s.cached_nodes.clear();
    }
    boxed
}

/// Restore live cached subscription nodes onto `target` when reverting or switching revisions.
pub fn preserve_live_cached_nodes(
    target: &mut RouterStoreData,
    current_store: Option<&RouterStoreData>,
) {
    let Some(cur) = current_store else {
        return;
    };
    let cur_nodes: HashMap<&str, &Vec<crate::store::ParsedProxyNode>> = cur
        .outbound_sources
        .iter()
        .filter(|s| !s.cached_nodes.is_empty())
        .map(|s| (s.id.as_str(), &s.cached_nodes))
        .collect();
    for src in &mut target.outbound_sources {
        if src.cached_nodes.is_empty()
            && let Some(nodes) = cur_nodes.get(src.id.as_str())
        {
            src.cached_nodes = (*nodes).clone();
        }
    }
}

/// Record a committed transaction diff in tmpfs, coalescing rapid `"save"` bursts into a single revision.
#[inline(never)]
pub fn record_commit_revision_in(
    dir: &Path,
    before: &RouterStoreData,
    after: &RouterStoreData,
    source: &str,
) -> Option<ConfigRevisionSummary> {
    let acc = compute_store_diff_detailed(before, after);
    if acc.total_changes() == 0 {
        return None;
    }

    let _guard = history_lock().lock().unwrap_or_else(|e| e.into_inner());
    if std::fs::create_dir_all(dir).is_err() {
        return None;
    }

    let now = unix_now_secs();
    if source == "save"
        && let Some(newest) = collect_sorted_summaries_in(dir).into_iter().next()
        && newest.source == "save"
        && now.saturating_sub(newest.timestamp) <= COALESCE_WINDOW_SECS
        && now >= newest.timestamp
    {
        let existing_path = dir.join(format!("{}.json", newest.id));
        if let Ok(mut prev_doc) = read_revision_file(&existing_path) {
            let coalesced_acc = compute_store_diff_detailed(&prev_doc.before_store, after);
            let total = coalesced_acc.total_changes();
            if total == 0 {
                let _ = std::fs::remove_file(&existing_path);
                return None;
            }
            let summary = ConfigRevisionSummary {
                id: newest.id,
                timestamp: now,
                source: "save".to_string(),
                status: default_revision_status(),
                status_reason: String::new(),
                added: coalesced_acc.added,
                changed: coalesced_acc.changed,
                removed: coalesced_acc.removed,
                total_changes: total,
                truncated: coalesced_acc.truncated(),
                changes: coalesced_acc.entries,
            };
            prev_doc.summary = summary.clone();
            prev_doc.after_store = Some(clone_store_without_cached_nodes(after));
            if write_revision_file(&existing_path, &prev_doc).is_ok() {
                return Some(summary);
            }
        }
    }

    let seq = REV_SEQ.fetch_add(1, Ordering::Relaxed) % 10_000;
    let id = format!("rev-{now}-{seq:04}-{}", crypto_gen::generate_hex(2));
    let summary = ConfigRevisionSummary {
        id: id.clone(),
        timestamp: now,
        source: source.to_string(),
        status: default_revision_status(),
        status_reason: String::new(),
        added: acc.added,
        changed: acc.changed,
        removed: acc.removed,
        total_changes: acc.total_changes(),
        truncated: acc.truncated(),
        changes: acc.entries,
    };

    let file_doc = Box::new(ConfigRevisionFile {
        summary: summary.clone(),
        before_store: clone_store_without_cached_nodes(before),
        after_store: Some(clone_store_without_cached_nodes(after)),
    });
    let file_path = dir.join(format!("{id}.json"));
    if write_revision_file(&file_path, &file_doc).is_err() {
        return None;
    }
    prune_old_revisions_in(dir, MAX_CONFIG_HISTORY_ENTRIES);
    Some(summary)
}

pub fn record_commit_revision(
    before: &RouterStoreData,
    after: &RouterStoreData,
    source: &str,
) -> Option<ConfigRevisionSummary> {
    record_commit_revision_in(&history_dir(), before, after, source)
}

/// Mark a recorded revision (or the latest revision if `target_id` is `None`) as `"checking"`, `"working"`, or `"failed"`.
#[inline(never)]
pub fn mark_revision_status_in(
    dir: &Path,
    target_id: Option<&str>,
    status: &str,
    reason: &str,
) -> Option<String> {
    let _guard = history_lock().lock().unwrap_or_else(|e| e.into_inner());
    let resolved_id = target_id
        .map(str::trim)
        .filter(|id| is_valid_revision_id(id))
        .map(str::to_string)
        .or_else(|| {
            collect_sorted_summaries_in(dir)
                .into_iter()
                .next()
                .map(|s| s.id)
        })?;
    let path = dir.join(format!("{resolved_id}.json"));
    if !path.is_file() {
        return None;
    }
    let mut doc = read_revision_file(&path).ok()?;
    doc.summary.status = status.to_string();
    doc.summary.status_reason = truncate_chars(reason.trim(), 200);
    if write_revision_file(&path, &doc).is_ok() {
        Some(resolved_id)
    } else {
        None
    }
}

pub fn mark_revision_status(target_id: Option<&str>, status: &str, reason: &str) -> Option<String> {
    mark_revision_status_in(&history_dir(), target_id, status, reason)
}

#[inline(never)]
pub fn list_revisions_in(dir: &Path) -> Vec<ConfigRevisionSummary> {
    let _guard = history_lock().lock().unwrap_or_else(|e| e.into_inner());
    collect_sorted_summaries_in(dir)
}

pub fn list_revisions() -> Vec<ConfigRevisionSummary> {
    list_revisions_in(&history_dir())
}

#[inline(never)]
pub fn load_revision_store_in(
    dir: &Path,
    id: &str,
    mode: &str,
    current_store: Option<&RouterStoreData>,
) -> anyhow::Result<Box<RouterStoreData>> {
    if !is_valid_revision_id(id) {
        anyhow::bail!("Недопустимый идентификатор ревизии");
    }
    let _guard = history_lock().lock().unwrap_or_else(|e| e.into_inner());
    let path = dir.join(format!("{id}.json"));
    if !path.is_file() {
        anyhow::bail!("Ревизия '{id}' не найдена");
    }
    let doc = read_revision_file(&path)?;
    let mut store = if mode.eq_ignore_ascii_case("after") {
        doc.after_store.unwrap_or(doc.before_store)
    } else {
        doc.before_store
    };
    preserve_live_cached_nodes(&mut store, current_store);
    Ok(store)
}

pub fn load_revision_store(
    id: &str,
    mode: &str,
    current_store: Option<&RouterStoreData>,
) -> anyhow::Result<Box<RouterStoreData>> {
    load_revision_store_in(&history_dir(), id, mode, current_store)
}

#[allow(dead_code)]
#[inline(never)]
pub fn load_revision_before_store_in(
    dir: &Path,
    id: &str,
    current_store: Option<&RouterStoreData>,
) -> anyhow::Result<Box<RouterStoreData>> {
    load_revision_store_in(dir, id, "before", current_store)
}

#[allow(dead_code)]
pub fn load_revision_before_store(
    id: &str,
    current_store: Option<&RouterStoreData>,
) -> anyhow::Result<Box<RouterStoreData>> {
    load_revision_before_store_in(&history_dir(), id, current_store)
}

/// Load the newest revision marked `"working"` along with its `after_store` snapshot.
#[inline(never)]
pub fn load_last_working_store_in(
    dir: &Path,
    current_store: Option<&RouterStoreData>,
) -> Option<(String, Box<RouterStoreData>)> {
    let _guard = history_lock().lock().unwrap_or_else(|e| e.into_inner());
    let summaries = collect_sorted_summaries_in(dir);
    for rev in summaries {
        if rev.status != "working" || !is_valid_revision_id(&rev.id) {
            continue;
        }
        let path = dir.join(format!("{}.json", rev.id));
        if let Ok(doc) = read_revision_file(&path)
            && let Some(mut after_store) = doc.after_store
        {
            preserve_live_cached_nodes(&mut after_store, current_store);
            return Some((rev.id, after_store));
        }
    }
    None
}

#[allow(dead_code)]
pub fn load_last_working_store(
    current_store: Option<&RouterStoreData>,
) -> Option<(String, Box<RouterStoreData>)> {
    load_last_working_store_in(&history_dir(), current_store)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::{OutboundSource, ParsedProxyNode, RoutingSection};

    fn temp_hist_dir(tag: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("tachyon-cfg-hist-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn test_diff_masks_secrets_and_covers_settings_and_sections() {
        let mut before = RouterStoreData::default();
        before.settings.fakeip_enabled = true;
        before.telegram.bot_token = "111:secret-old".to_string();
        before.outbound_sources.push(OutboundSource {
            id: "src_1".to_string(),
            name: "Main Node".to_string(),
            password: "old-password".to_string(),
            uuid: "11111111-1111-1111-1111-111111111111".to_string(),
            ..Default::default()
        });
        before.sections.push(RoutingSection {
            id: "sec_old".to_string(),
            label: "Old Sec".to_string(),
            enabled: true,
            ..Default::default()
        });
        before.sections.push(RoutingSection {
            id: "sec_keep".to_string(),
            label: "Keep Sec".to_string(),
            enabled: true,
            ..Default::default()
        });

        let mut after = before.clone();
        after.settings.fakeip_enabled = false;
        after.telegram.bot_token = "222:secret-new".to_string();
        after.outbound_sources[0].password = "new-password".to_string();
        after.outbound_sources[0].uuid = "22222222-2222-2222-2222-222222222222".to_string();
        after.sections.retain(|s| s.id != "sec_old");
        if let Some(keep_sec) = after.sections.iter_mut().find(|s| s.id == "sec_keep") {
            keep_sec.enabled = false;
        }
        after.sections.push(RoutingSection {
            id: "sec_new".to_string(),
            label: "New Sec".to_string(),
            enabled: true,
            ..Default::default()
        });

        let (entries, truncated) = compute_store_diff(&before, &after);
        assert_eq!(truncated, 0);
        let serialized = serde_json::to_string(&entries).unwrap();
        assert!(!serialized.contains("secret-old"));
        assert!(!serialized.contains("secret-new"));
        assert!(!serialized.contains("old-password"));
        assert!(!serialized.contains("new-password"));
        assert!(!serialized.contains("11111111-1111"));
        assert!(!serialized.contains("22222222-2222"));

        assert!(entries.iter().any(|e| {
            e.scope == "settings"
                && e.field == "fakeip_enabled"
                && e.before == "true"
                && e.after == "false"
        }));
        assert!(entries.iter().any(|e| {
            e.scope == "telegram" && e.field == "bot_token" && e.before == "***" && e.after == "***"
        }));
        assert!(entries.iter().any(|e| {
            e.scope == "section" && e.kind == "removed" && e.target.contains("sec_old")
        }));
        assert!(entries.iter().any(|e| {
            e.scope == "section" && e.kind == "added" && e.target.contains("sec_new")
        }));
        assert!(entries.iter().any(|e| {
            e.scope == "section" && e.target.contains("sec_keep") && e.field == "enabled"
        }));
    }

    #[test]
    fn test_ignores_subscription_telemetry_changes() {
        let dir = temp_hist_dir("ignore_sub_telem");
        let mut before = RouterStoreData::default();
        before.outbound_sources.push(OutboundSource {
            id: "sub_1".to_string(),
            source_type: "subscription".to_string(),
            name: "Sub".to_string(),
            last_updated_unix: 100,
            sub_download_bytes: 500,
            cached_nodes: vec![ParsedProxyNode {
                tag: "node-a".to_string(),
                ..Default::default()
            }],
            ..Default::default()
        });
        let mut after = before.clone();
        after.outbound_sources[0].last_updated_unix = 200;
        after.outbound_sources[0].sub_download_bytes = 9999;
        after.outbound_sources[0].sub_title = "Updated Title".to_string();
        after.outbound_sources[0]
            .cached_nodes
            .push(ParsedProxyNode {
                tag: "node-b".to_string(),
                ..Default::default()
            });
        after
            .applied_migrations
            .push("legacy_uci_imported".to_string());

        assert!(record_commit_revision_in(&dir, &before, &after, "save").is_none());
        assert!(list_revisions_in(&dir).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_coalesces_rapid_saves_and_keeps_rollback_separate() {
        let dir = temp_hist_dir("coalesce");
        let s0 = RouterStoreData::default();
        let mut s1 = s0.clone();
        s1.settings.tun_mtu = 1400;
        let mut s2 = s1.clone();
        s2.settings.dns_type = "doh".to_string();

        let rev1 = record_commit_revision_in(&dir, &s0, &s1, "save").expect("rev1");
        let rev2 = record_commit_revision_in(&dir, &s1, &s2, "save").expect("rev2 coalesced");
        assert_eq!(
            rev1.id, rev2.id,
            "rapid saves must coalesce into one revision"
        );
        assert_eq!(rev2.total_changes, 2);

        let list = list_revisions_in(&dir);
        assert_eq!(list.len(), 1);

        // Rolling back to rev2 restores s0 cleanly and adds a distinct 'rollback' revision
        let restored = load_revision_before_store_in(&dir, &rev2.id, Some(&s2)).unwrap();
        assert_eq!(restored.settings.tun_mtu, s0.settings.tun_mtu);
        let rb_rev = record_commit_revision_in(&dir, &s2, &restored, "rollback")
            .expect("rollback revision recorded separately");
        assert_ne!(rb_rev.id, rev2.id);
        assert_eq!(rb_rev.source, "rollback");
        assert_eq!(list_revisions_in(&dir).len(), 2);

        // Reverting back manually within coalesce window removes empty net diff
        let mut back = s2.clone();
        back.settings.tun_mtu = s0.settings.tun_mtu;
        let rev_rb_check = record_commit_revision_in(&dir, &s2, &back, "save").unwrap();
        let list_before_cancel = list_revisions_in(&dir).len();
        assert!(list_before_cancel >= 2);
        let _ = rev_rb_check;
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_rotation_at_20_and_rejects_path_traversal() {
        let dir = temp_hist_dir("rotation");
        let mut cur = RouterStoreData::default();
        for idx in 1..=25 {
            let mut next = cur.clone();
            next.settings.tun_mtu = 1300 + idx as u16;
            // Alternate source to avoid 3s coalescing in tight loop
            let src = if idx % 2 == 0 { "save" } else { "rollback" };
            record_commit_revision_in(&dir, &cur, &next, src).expect("revision created");
            cur = next;
        }
        let listed = list_revisions_in(&dir);
        assert_eq!(listed.len(), MAX_CONFIG_HISTORY_ENTRIES);

        assert!(load_revision_before_store_in(&dir, "../etc/passwd", None).is_err());
        assert!(load_revision_before_store_in(&dir, "bad/id", None).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_revision_status_marking_and_load_last_working_store() {
        let dir = temp_hist_dir("status_working");
        let mut s0 = RouterStoreData::default();
        s0.settings.tun_mtu = 1480;
        let mut s1 = s0.clone();
        s1.settings.tun_mtu = 1420;
        let mut s2 = s1.clone();
        s2.settings.tun_mtu = 1360;

        let rev1 = record_commit_revision_in(&dir, &s0, &s1, "save").expect("rev1");
        assert_eq!(rev1.status, "checking");
        let marked_work =
            mark_revision_status_in(&dir, Some(&rev1.id), "working", "Проверен (LKG)")
                .expect("marked working");
        assert_eq!(marked_work, rev1.id);

        // Use "rollback" source on rev2 to avoid 3s coalescing with rev1.
        let rev2 = record_commit_revision_in(&dir, &s1, &s2, "rollback").expect("rev2");
        let marked_fail =
            mark_revision_status_in(&dir, None, "failed", "Ошибка применения конфига")
                .expect("marked failed");
        assert_eq!(marked_fail, rev2.id);

        let list = list_revisions_in(&dir);
        let r1_sum = list.iter().find(|r| r.id == rev1.id).unwrap();
        let r2_sum = list.iter().find(|r| r.id == rev2.id).unwrap();
        assert_eq!(r1_sum.status, "working");
        assert_eq!(r1_sum.status_reason, "Проверен (LKG)");
        assert_eq!(r2_sum.status, "failed");
        assert_eq!(r2_sum.status_reason, "Ошибка применения конфига");

        let rev1_after = load_revision_store_in(&dir, &rev1.id, "after", None).unwrap();
        assert_eq!(rev1_after.settings.tun_mtu, 1420);

        let (best_id, best_store) =
            load_last_working_store_in(&dir, None).expect("working store found");
        assert_eq!(best_id, rev1.id);
        assert_eq!(best_store.settings.tun_mtu, 1420);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_scalar_array_diff_shows_exact_added_and_removed_delta() {
        let dir = temp_hist_dir("array_delta");
        let mut s0 = RouterStoreData::default();
        s0.sections[0].user_domains = (0..160).map(|i| format!("dom{i}.example")).collect();

        let mut s1 = s0.clone();
        s1.sections[0].user_domains.push("mijia.tech".to_string());

        let rev_add =
            record_commit_revision_in(&dir, &s0, &s1, "smart_detect").expect("add revision");
        assert_eq!(rev_add.source, "smart_detect");
        let add_entry = rev_add
            .changes
            .iter()
            .find(|c| c.field == "user_domains")
            .expect("user_domains add entry");
        assert_eq!(add_entry.before, "[160]");
        assert_eq!(add_entry.after, "+ mijia.tech (161)");

        let mut s2 = s1.clone();
        s2.sections[0].user_domains.retain(|d| d != "dom0.example");
        // Use a different source to avoid 3s coalescing with rev_add.
        let rev_rem = record_commit_revision_in(&dir, &s1, &s2, "save").expect("remove revision");
        let rem_entry = rev_rem
            .changes
            .iter()
            .find(|c| c.field == "user_domains")
            .expect("user_domains remove entry");
        assert_eq!(rem_entry.before, "- dom0.example (161)");
        assert_eq!(rem_entry.after, "[160]");

        let _ = std::fs::remove_dir_all(&dir);
    }
}
