//! Passive history of selected outbounds. The daemon is the only writer.
use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::sync::{Arc, atomic::Ordering::Relaxed};
use std::time::Instant;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::store::PortableAtomicU64;

pub(crate) const LIMIT: usize = 100;
const MAX_BYTES: usize = 128 * 1024;
const MAX_GROUPS: usize = 512;
const MAX_TIER_MEMBERS: usize = 4096;
const MAX_TIMESTAMP: u64 = 253_402_300_799;

pub(crate) fn path() -> PathBuf {
    PathBuf::from("/var/run/tachyon/selector_events.json")
}

#[derive(Clone, Copy, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
enum Reason {
    Initial,
    Failover,
    Recovery,
    FasterSameTier,
    Switch,
    #[serde(alias = "active_unhealthy")]
    ActiveIneligible,
    HigherPriorityEligible,
    ManualRestore,
    #[default]
    #[serde(other)]
    Unknown,
}

#[derive(Clone, Copy, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Source {
    #[default]
    LegacyPriority,
    ClashProxies,
    CoreFailover,
}

#[derive(Default, Deserialize, Serialize)]
#[serde(default)]
pub(crate) struct Event {
    #[serde(alias = "ts")]
    timestamp: u64,
    group: String,
    from: String,
    to: String,
    reason: Reason,
    #[serde(skip_serializing_if = "Option::is_none")]
    decided_at: Option<u64>,
    source: Source,
    observed: bool,
    priority: Option<bool>,
    old_level: Option<u32>,
    new_level: Option<u32>,
    #[serde(alias = "from_delay")]
    from_delay_ms: Option<u32>,
    #[serde(alias = "to_delay")]
    to_delay_ms: Option<u32>,
    from_delay_at: Option<String>,
    to_delay_at: Option<String>,
    check_urls: Vec<String>,
    from_quarantined: Option<bool>,
    to_quarantined: Option<bool>,
    on_backup: Option<bool>,
    primary: Option<String>,
    primary_healthy: Option<bool>,
    primary_failures: Option<u32>,
    previous_switch_at: Option<u64>,
    // The 1.x Priority worker used a zero-based index.
    #[serde(rename = "level", skip_serializing)]
    legacy_level: Option<u32>,
}

fn identifier(value: &str) -> bool {
    !value.trim().is_empty()
        && value.len() <= 384
        && !value.contains("://")
        && !value.chars().any(char::is_control)
}

fn check_url(value: &str) -> Option<String> {
    let (scheme, rest) = value.split_once("://")?;
    if !matches!(scheme, "http" | "https") {
        return None;
    }
    let (authority, path) = rest
        .split_once(['/', '?', '#'])
        .map_or((rest, ""), |(authority, _)| {
            (authority, &rest[authority.len()..])
        });
    let host = authority.rsplit('@').next()?;
    if host.is_empty()
        || host.len() > 255
        || !host
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b".-:[]".contains(&c))
    {
        return None;
    }
    // Custom paths, credentials and URL parameters can contain tokens.
    let path = path.split(['?', '#']).next().unwrap_or("");
    let path = match path {
        "/generate_204" | "/gen_204" | "/connecttest.txt" | "/hotspot-detect.html" => path,
        _ => "",
    };
    Some(format!("{scheme}://{host}{path}"))
}

fn number(value: &Value) -> Option<u32> {
    value.as_u64().and_then(|value| value.try_into().ok())
}

fn sample_time(value: &str) -> bool {
    value.len() <= 40
        && value.contains('T')
        && value
            .bytes()
            .all(|c| c.is_ascii_digit() || b"TtZz+-:.".contains(&c))
}

fn parse_known_reason(raw: &str) -> Option<Reason> {
    match raw.trim() {
        "initial" => Some(Reason::Initial),
        "failover" => Some(Reason::Failover),
        "recovery" => Some(Reason::Recovery),
        "faster_same_tier" => Some(Reason::FasterSameTier),
        "switch" => Some(Reason::Switch),
        "active_ineligible" | "active_unhealthy" => Some(Reason::ActiveIneligible),
        "higher_priority_eligible" => Some(Reason::HigherPriorityEligible),
        "manual_restore" => Some(Reason::ManualRestore),
        _ => None,
    }
}

fn days_from_civil(y: i64, m: i64, d: i64) -> Option<i64> {
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return None;
    }
    let leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);
    let max_day = match m {
        2 => {
            if leap {
                29
            } else {
                28
            }
        }
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    };
    if d > max_day {
        return None;
    }
    let y = y - i64::from(m <= 2);
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    Some(era * 146_097 + doe - 719_468)
}

fn parse_decision_timestamp(value: &Value) -> Option<u64> {
    if let Some(secs) = value.as_u64() {
        return (1..=MAX_TIMESTAMP).contains(&secs).then_some(secs);
    }
    let s = value.as_str()?.trim();
    let (date_str, rest) = s.split_once(['T', 't'])?;
    let mut dp = date_str.split('-');
    let year: i64 = dp.next().filter(|p| p.len() == 4)?.parse().ok()?;
    let month: i64 = dp.next().filter(|p| p.len() == 2)?.parse().ok()?;
    let day: i64 = dp.next().filter(|p| p.len() == 2)?.parse().ok()?;
    if dp.next().is_some() {
        return None;
    }
    let days = days_from_civil(year, month, day)?;

    let (time_and_frac, offset_secs): (&str, i64) =
        if let Some(bare) = rest.strip_suffix(['Z', 'z']) {
            (bare, 0)
        } else {
            let idx = rest.rfind(['+', '-'])?;
            let sign = if &rest[idx..=idx] == "+" { 1i64 } else { -1i64 };
            let tz = &rest[idx + 1..];
            let (hh_s, mm_s) = tz.split_once(':')?;
            if hh_s.len() != 2 || mm_s.len() != 2 {
                return None;
            }
            let hh: i64 = hh_s.parse().ok()?;
            let mm: i64 = mm_s.parse().ok()?;
            if hh > 23 || mm > 59 {
                return None;
            }
            (&rest[..idx], sign * (hh * 3600 + mm * 60))
        };

    let hms = time_and_frac
        .split_once('.')
        .map_or(time_and_frac, |(main, frac)| {
            if !frac.is_empty() && frac.bytes().all(|b| b.is_ascii_digit()) {
                main
            } else {
                ""
            }
        });
    let mut tp = hms.split(':');
    let hour: i64 = tp.next().filter(|p| p.len() == 2)?.parse().ok()?;
    let minute: i64 = tp.next().filter(|p| p.len() == 2)?.parse().ok()?;
    let second: i64 = tp.next().filter(|p| p.len() == 2)?.parse().ok()?;
    if tp.next().is_some() || hour > 23 || minute > 59 || second > 59 {
        return None;
    }

    let total = days
        .checked_mul(86_400)?
        .checked_add(hour * 3600 + minute * 60 + second)?
        .checked_sub(offset_secs)?;
    let secs = u64::try_from(total).ok()?;
    (1..=MAX_TIMESTAMP).contains(&secs).then_some(secs)
}

fn read_events(path: &Path) -> io::Result<Vec<Event>> {
    let mut raw = Vec::new();
    match File::open(path) {
        Ok(file) => file.take((MAX_BYTES + 1) as u64).read_to_end(&mut raw)?,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(err) => return Err(err),
    };
    if raw.len() > MAX_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "switch history too large",
        ));
    }

    let values: Vec<Value> = serde_json::from_slice(&raw)
        .map_err(|err| io::Error::new(io::ErrorKind::InvalidData, err))?;
    let mut events = Vec::new();
    let mut last_by_group = HashMap::new();
    for value in values.into_iter().rev().take(LIMIT).rev() {
        let Ok(mut event) = serde_json::from_value::<Event>(value) else {
            continue;
        };
        if !(1..=MAX_TIMESTAMP).contains(&event.timestamp)
            || !identifier(&event.group)
            || !identifier(&event.to)
            || (!event.from.is_empty() && !identifier(&event.from))
            || event.from == event.to
        {
            continue;
        }
        event.new_level = event
            .new_level
            .or_else(|| event.legacy_level.and_then(|level| level.checked_add(1)));
        event.from_delay_ms = event.from_delay_ms.filter(|delay| *delay > 0);
        event.to_delay_ms = event.to_delay_ms.filter(|delay| *delay > 0);
        event.from_delay_at = event.from_delay_at.filter(|value| sample_time(value));
        event.to_delay_at = event.to_delay_at.filter(|value| sample_time(value));
        event.check_urls = event
            .check_urls
            .iter()
            .take(8)
            .filter_map(|url| check_url(url))
            .collect();
        event.primary = event.primary.filter(|value| identifier(value));
        event.decided_at = event
            .decided_at
            .filter(|ts| (1..=MAX_TIMESTAMP).contains(ts));
        event.previous_switch_at = event
            .previous_switch_at
            .filter(|time| (1..=MAX_TIMESTAMP).contains(time))
            .or_else(|| last_by_group.get(&event.group).copied());
        last_by_group.insert(event.group.clone(), event.timestamp);
        events.push(event);
    }
    Ok(events)
}

pub(crate) fn recent(
    path: &Path,
    limit: usize,
    group: &str,
    reason: &str,
) -> io::Result<Vec<Event>> {
    let reason = if reason.is_empty() {
        None
    } else if reason == "unknown" {
        Some(Reason::Unknown)
    } else {
        match parse_known_reason(reason) {
            Some(r) => Some(r),
            None => return Ok(Vec::new()),
        }
    };
    Ok(read_events(path)?
        .into_iter()
        .rev()
        .filter(|event| {
            (group.is_empty() || event.group == group)
                && reason.is_none_or(|reason| event.reason == reason)
        })
        .take(limit.min(LIMIT))
        .collect())
}

#[cfg(test)]
fn append(path: &Path, incoming: Vec<Event>) -> anyhow::Result<()> {
    append_with_retries(path, incoming, 0, std::time::Duration::ZERO).map(|_| ())
}

fn append_with_retries(
    path: &Path,
    incoming: Vec<Event>,
    retries: usize,
    backoff: std::time::Duration,
) -> anyhow::Result<usize> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    // Also serialize a brief overlap during daemon replacement.
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(path.with_extension("lock"))?;
    let mut attempt = 0;
    loop {
        match lock.try_lock() {
            Ok(()) => break,
            Err(std::fs::TryLockError::WouldBlock) if attempt < retries => {
                attempt += 1;
                std::thread::sleep(backoff);
            }
            Err(err) => return Err(err.into()),
        }
    }
    let mut events = match read_events(path) {
        Ok(events) => events,
        Err(err)
            if matches!(
                err.kind(),
                io::ErrorKind::InvalidData | io::ErrorKind::Other
            ) =>
        {
            Vec::new()
        }
        Err(err) => return Err(err.into()),
    };
    let prior_count = events.len();
    for mut event in incoming {
        if let Some(last) = events.iter().rev().find(|last| last.group == event.group) {
            if (last.timestamp, &last.from, &last.to) == (event.timestamp, &event.from, &event.to) {
                continue;
            }
            event.previous_switch_at = Some(last.timestamp);
        }
        events.push(event);
    }
    let appended = events.len() - prior_count;
    events.drain(..events.len().saturating_sub(LIMIT));
    let mut bytes = serde_json::to_vec(&events)?;
    while bytes.len() > MAX_BYTES {
        events.remove(0);
        bytes = serde_json::to_vec(&events)?;
    }
    crate::crypto_gen::write_file_if_changed(path, &bytes)?;
    Ok(appended.min(events.len()))
}

struct Group {
    priority: bool,
    levels: HashMap<String, u32>,
    check_url: Option<String>,
}

#[derive(Default)]
pub(crate) struct Groups(HashMap<String, Group>);

impl Groups {
    pub(crate) fn from_config(config: &Value) -> Self {
        let Some(outbounds) = config.get("outbounds").and_then(Value::as_array) else {
            return Self::default();
        };
        let mut tier_members_left = MAX_TIER_MEMBERS;
        Self(
            outbounds
                .iter()
                .filter_map(|outbound| {
                    let tag = outbound.get("tag")?.as_str()?.trim();
                    if !identifier(tag) || outbound.get("type")?.as_str()? != "urltest" {
                        return None;
                    }
                    let mut levels = HashMap::new();
                    if let Some(tiers) = outbound
                        .pointer("/balancer/tiers")
                        .and_then(Value::as_array)
                    {
                        'tiers: for (index, tier) in tiers.iter().enumerate() {
                            for node in tier
                                .as_array()
                                .into_iter()
                                .flatten()
                                .filter_map(Value::as_str)
                            {
                                if tier_members_left == 0 {
                                    break 'tiers;
                                }
                                if identifier(node) {
                                    tier_members_left -= 1;
                                    levels.entry(node.to_owned()).or_insert(index as u32 + 1);
                                }
                            }
                        }
                    }
                    let mode = outbound.get("mode").and_then(Value::as_str);
                    let priority = mode == Some("priority")
                        || outbound
                            .pointer("/balancer/tiers")
                            .and_then(Value::as_array)
                            .is_some_and(|tiers| !tiers.is_empty());
                    if !priority && !matches!(mode, None | Some("least_test" | "urltest")) {
                        return None;
                    }
                    Some((
                        tag.to_owned(),
                        Group {
                            priority,
                            levels,
                            check_url: outbound
                                .get("url")
                                .and_then(Value::as_str)
                                .and_then(check_url),
                        },
                    ))
                })
                .take(MAX_GROUPS)
                .collect(),
        )
    }
}

struct GroupCursor {
    selected: String,
    generation: Option<String>,
    sequence: Option<u64>,
}

#[derive(Default)]
pub(crate) struct Observer {
    config: Option<Arc<Groups>>,
    core: Option<(u32, u64)>,
    last_sample: Option<Instant>,
    cursors: HashMap<String, GroupCursor>,
}

impl Observer {
    fn transitions(
        &mut self,
        config: Arc<Groups>,
        core: (u32, u64),
        started: Instant,
        source: Source,
        snapshot: &Value,
    ) -> Option<Vec<Event>> {
        let proxies = snapshot.get("proxies").and_then(Value::as_object);
        let failover = snapshot.get("groups").and_then(Value::as_array);
        if match source {
            Source::ClashProxies => proxies.is_none_or(serde_json::Map::is_empty),
            Source::CoreFailover => failover.is_none_or(Vec::is_empty),
            Source::LegacyPriority => true,
        } || self.last_sample.is_some_and(|last| started < last)
        {
            return None;
        }
        self.last_sample = Some(Instant::now());
        if self.core != Some(core)
            || !self
                .config
                .as_ref()
                .is_some_and(|prev| Arc::ptr_eq(prev, &config))
        {
            self.cursors.clear();
            self.core = Some(core);
            self.config = Some(Arc::clone(&config));
        }

        let mut events = Vec::new();
        let mut inspect = |tag: &str, status: &Value, selected_key: &str| {
            let Some(group) = config.0.get(tag) else {
                return;
            };
            let Some(to) = status
                .get(selected_key)
                .and_then(Value::as_str)
                .filter(|node| identifier(node))
            else {
                return;
            };
            let generation = status
                .get("switch_generation")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| identifier(s))
                .map(str::to_owned);
            let sequence = status.get("switch_sequence").and_then(Value::as_u64);

            let prev = match self.cursors.get(tag) {
                None => {
                    // The first sample establishes a baseline; it supplies no earlier selection.
                    self.cursors.insert(
                        tag.to_owned(),
                        GroupCursor {
                            selected: to.to_owned(),
                            generation,
                            sequence,
                        },
                    );
                    return;
                }
                Some(prev) if prev.selected == to => {
                    self.cursors.insert(
                        tag.to_owned(),
                        GroupCursor {
                            selected: to.to_owned(),
                            generation,
                            sequence,
                        },
                    );
                    return;
                }
                Some(prev) => GroupCursor {
                    selected: prev.selected.clone(),
                    generation: prev.generation.clone(),
                    sequence: prev.sequence,
                },
            };

            self.cursors.insert(
                tag.to_owned(),
                GroupCursor {
                    selected: to.to_owned(),
                    generation: generation.clone(),
                    sequence,
                },
            );

            let from = prev.selected;
            let (reason, decided_at) = match (
                prev.generation.as_deref(),
                generation.as_deref(),
                prev.sequence,
                sequence,
                status.get("last_switch").and_then(Value::as_object),
            ) {
                (Some(pg), Some(cg), Some(ps), Some(cs), Some(last))
                    if pg == cg && cs == ps.saturating_add(1) =>
                {
                    let ls_from = last.get("from").and_then(Value::as_str).unwrap_or("");
                    let ls_to = last.get("to").and_then(Value::as_str).unwrap_or("");
                    let parsed_reason = last
                        .get("reason")
                        .and_then(Value::as_str)
                        .and_then(parse_known_reason);
                    match parsed_reason {
                        Some(r) if ls_from == from && ls_to == to => {
                            let d_at = last.get("timestamp").and_then(parse_decision_timestamp);
                            (r, d_at)
                        }
                        _ => (Reason::Unknown, None),
                    }
                }
                _ => (Reason::Unknown, None),
            };

            let (from_delay_ms, from_delay_at) = delay(proxies, status, &from);
            let (to_delay_ms, to_delay_at) = delay(proxies, status, to);
            let quarantined = |node| {
                status
                    .get("telemetry")?
                    .get(node)?
                    .get("quarantined")?
                    .as_bool()
            };
            let primary = status
                .get("primary")
                .and_then(Value::as_str)
                .filter(|node| identifier(node));
            events.push(Event {
                timestamp: crate::store::unix_now_u64(),
                group: tag.to_owned(),
                old_level: group.levels.get(&from).copied(),
                new_level: group.levels.get(to).copied(),
                from_delay_ms,
                from_delay_at,
                to_delay_ms,
                to_delay_at,
                from_quarantined: quarantined(from.as_str()),
                to_quarantined: quarantined(to),
                from,
                to: to.to_owned(),
                reason,
                decided_at,
                source,
                observed: true,
                priority: Some(group.priority),
                check_urls: group.check_url.clone().into_iter().collect(),
                on_backup: status.get("on_backup").and_then(Value::as_bool),
                primary: primary.map(str::to_owned),
                primary_healthy: primary.and_then(|_| status.get("primary_healthy")?.as_bool()),
                primary_failures: primary.and_then(|_| number(status.get("primary_failures")?)),
                ..Event::default()
            });
        };
        match source {
            Source::ClashProxies => {
                if let Some(proxies) = proxies {
                    for tag in config.0.keys() {
                        if let Some(group) = proxies.get(tag) {
                            inspect(tag, group, "now");
                        }
                    }
                }
            }
            Source::CoreFailover => {
                for group in failover.into_iter().flatten() {
                    if let Some(tag) = group.get("tag").and_then(Value::as_str) {
                        inspect(tag, group, "current");
                    }
                }
            }
            Source::LegacyPriority => {}
        }
        Some(events)
    }
}

#[derive(Default)]
struct RecorderCounters {
    written: PortableAtomicU64,
    dropped: PortableAtomicU64,
    write_errors: PortableAtomicU64,
    last_write_at: PortableAtomicU64,
}

#[derive(Serialize, Default)]
pub(crate) struct RecorderStats {
    // Newly persisted events, excluding deduplication and normal journal rotation.
    written: u64,
    // Events discarded by the queue or after a failed write.
    dropped: u64,
    write_errors: u64,
    last_write_at: Option<u64>,
}

pub(crate) struct Recorder {
    counters: Arc<RecorderCounters>,
    observer: std::sync::Mutex<Observer>,
    tx: tokio::sync::mpsc::Sender<Vec<Event>>,
}

impl Recorder {
    pub(crate) fn spawn(journal_path: PathBuf) -> Self {
        let (tx, mut rx) = tokio::sync::mpsc::channel::<Vec<Event>>(64);
        let counters = Arc::new(RecorderCounters::default());
        let worker_counters = Arc::clone(&counters);
        tokio::spawn(async move {
            while let Some(mut batch) = rx.recv().await {
                while let Ok(more) = rx.try_recv() {
                    batch.extend(more);
                }
                if batch.is_empty() {
                    continue;
                }
                let path = journal_path.clone();
                let event_count = batch.len() as u64;
                match tokio::task::spawn_blocking(move || {
                    append_with_retries(&path, batch, 4, std::time::Duration::from_millis(25))
                })
                .await
                {
                    Ok(Ok(written)) if written > 0 => {
                        worker_counters.written.fetch_add(written as u64, Relaxed);
                        worker_counters
                            .last_write_at
                            .store(crate::store::unix_now_secs().max(0) as u64, Relaxed);
                    }
                    Ok(Ok(_)) => {}
                    _ => {
                        worker_counters.write_errors.fetch_add(1, Relaxed);
                        worker_counters.dropped.fetch_add(event_count, Relaxed);
                    }
                }
            }
        });
        Self {
            counters,
            observer: std::sync::Mutex::new(Observer::default()),
            tx,
        }
    }

    pub(crate) fn stats(&self) -> RecorderStats {
        let last_write_at = self.counters.last_write_at.load(Relaxed);
        RecorderStats {
            written: self.counters.written.load(Relaxed),
            dropped: self.counters.dropped.load(Relaxed),
            write_errors: self.counters.write_errors.load(Relaxed),
            last_write_at: (last_write_at != 0).then_some(last_write_at),
        }
    }

    pub(crate) fn observe(
        &self,
        config: Arc<Groups>,
        core: (u32, u64),
        started: Instant,
        source: Source,
        snapshot: &Value,
    ) {
        let events = {
            let Ok(mut observer) = self.observer.lock() else {
                return;
            };
            observer.transitions(config, core, started, source, snapshot)
        };
        if let Some(events) = events
            && !events.is_empty()
            && let Err(err) = self.tx.try_send(events)
        {
            self.counters
                .dropped
                .fetch_add(err.into_inner().len() as u64, Relaxed);
        }
    }
}

fn delay(
    proxies: Option<&serde_json::Map<String, Value>>,
    status: &Value,
    node: &str,
) -> (Option<u32>, Option<String>) {
    if let Some(history) = proxies
        .and_then(|proxies| proxies.get(node))
        .and_then(|node| node.get("history")?.as_array()?.last())
        && let Some(ms) = history.get("delay").and_then(number).filter(|ms| *ms > 0)
    {
        let time = history
            .get("time")
            .and_then(Value::as_str)
            .filter(|time| sample_time(time));
        return (Some(ms), time.map(str::to_owned));
    }
    let rtt = status
        .get("telemetry")
        .and_then(|telemetry| telemetry.get(node)?.get("rtt_ms"))
        .and_then(number)
        .or_else(|| {
            (status.get("primary")?.as_str()? == node)
                .then(|| status.get("primary_rtt_ms").and_then(number))
                .flatten()
        })
        .filter(|ms| *ms > 0);
    (rtt, None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    struct TestDir(PathBuf);

    impl TestDir {
        fn new() -> Self {
            let dir = std::env::temp_dir().join(format!(
                "tachyon-switch-history-{}-{:016x}",
                std::process::id(),
                rand::random::<u64>()
            ));
            std::fs::create_dir(&dir).unwrap();
            Self(dir)
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn config() -> Arc<Groups> {
        Arc::new(Groups::from_config(&json!({"outbounds": [
            {"tag":"priority", "type":"urltest", "mode":"least_test",
             "url":"https://alice:secret@checks.example/generate_204?token=secret",
             "balancer":{"tiers":[["A", "Fast"], ["B"]]}},
            {"tag":"native", "type":"urltest", "mode":"least_test", "url":"https://checks.example/token/secret"},
            {"tag":"quota", "type":"urltest", "mode":"quota"},
            {"tag":"manual", "type":"selector"}
        ]})))
    }

    fn proxies(primary: &str, native: &str, quarantined: bool) -> Value {
        json!({"proxies": {
            "priority": {"now": primary, "telemetry": {"A": {"rtt_ms": 0, "quarantined": quarantined}}},
            "native": {"now": native},
            "manual": {"now": primary},
            "quota": {"now": primary},
            "A": {"history":[{"delay": 0}]},
            "Fast": {"history":[{"delay": 10}]},
            "B": {"history":[{"delay": 50, "time": "2026-11-22T10:00:00.000Z"}]}
        }})
    }

    fn observe(observer: &mut Observer, groups: &Arc<Groups>, snapshot: &Value) -> Vec<Event> {
        observer
            .transitions(
                Arc::clone(groups),
                (1, 10),
                Instant::now(),
                Source::ClashProxies,
                snapshot,
            )
            .unwrap()
    }

    #[test]
    fn priority_and_native_observe_changes_and_preserve_uncertainty() {
        let groups = config();
        let mut observer = Observer::default();
        // First sample, stable reads and failed probes without a new selection.
        for quarantine in [false, false, true, false, true, true] {
            assert!(observe(&mut observer, &groups, &proxies("A", "X", quarantine)).is_empty());
        }

        let changed = observe(&mut observer, &groups, &proxies("B", "Y", true));
        assert_eq!(changed.len(), 2);
        let priority = changed.iter().find(|ev| ev.group == "priority").unwrap();
        assert!(priority.reason == Reason::Unknown && priority.observed);
        assert_eq!((priority.old_level, priority.new_level), (Some(1), Some(2)));
        assert_eq!(
            (priority.from_delay_ms, priority.to_delay_ms),
            (None, Some(50))
        );
        assert_eq!(
            priority.to_delay_at.as_deref(),
            Some("2026-11-22T10:00:00.000Z")
        );
        assert_eq!(priority.from_quarantined, Some(true));
        assert_eq!(priority.check_urls, ["https://checks.example/generate_204"]);
        let native = changed.iter().find(|ev| ev.group == "native").unwrap();
        assert!(native.reason == Reason::Unknown && native.observed);
        assert_eq!(native.old_level, None);
        assert_eq!(native.check_urls, ["https://checks.example"]);
        assert!(observe(&mut observer, &groups, &proxies("B", "Y", true)).is_empty());

        let returned = observe(&mut observer, &groups, &proxies("A", "Y", false));
        assert_eq!(returned.len(), 1);
        assert_eq!(
            (returned[0].old_level, returned[0].new_level),
            (Some(2), Some(1))
        );
        let same_tier = observe(&mut observer, &groups, &proxies("Fast", "Y", false));
        assert_eq!(
            (same_tier[0].old_level, same_tier[0].new_level),
            (Some(1), Some(1))
        );
        assert!(same_tier[0].reason == Reason::Unknown);
    }

    #[test]
    fn shared_observer_deduplicates_sources_and_rejects_late_replies() {
        let mut observer = Observer::default();
        let groups = config();
        let earlier = Instant::now();
        assert!(observe(&mut observer, &groups, &proxies("A", "X", false)).is_empty());
        let snapshot = json!({"groups": [{
            "tag":"priority", "current":"B", "on_backup":true,
            "primary":"A", "primary_healthy":false, "primary_failures":7,"primary_rtt_ms":22
        }]});
        let changed = observer
            .transitions(
                Arc::clone(&groups),
                (1, 10),
                Instant::now(),
                Source::CoreFailover,
                &snapshot,
            )
            .unwrap();
        assert_eq!(changed.len(), 1);
        assert_eq!(changed[0].on_backup, Some(true));
        assert_eq!(changed[0].primary_failures, Some(7));
        assert_eq!(changed[0].from_delay_ms, Some(22));
        assert!(changed[0].reason == Reason::Unknown);
        assert!(observe(&mut observer, &groups, &proxies("B", "X", true)).is_empty());
        assert!(
            observer
                .transitions(
                    Arc::clone(&groups),
                    (1, 10),
                    earlier,
                    Source::ClashProxies,
                    &proxies("A", "X", false)
                )
                .is_none()
        );
        // Core restart and new config both start a new baseline.
        assert!(
            observer
                .transitions(
                    Arc::clone(&groups),
                    (1, 20),
                    Instant::now(),
                    Source::ClashProxies,
                    &proxies("A", "X", false)
                )
                .unwrap()
                .is_empty()
        );
        assert!(
            observer
                .transitions(
                    config(),
                    (1, 20),
                    Instant::now(),
                    Source::ClashProxies,
                    &proxies("B", "X", true)
                )
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn reads_legacy_filters_and_bounds_the_file() {
        let dir = TestDir::new();
        let path = dir.0.join("events.json");
        assert!(recent(&path, LIMIT, "", "").unwrap().is_empty());
        std::fs::write(&path, serde_json::to_vec(&json!([
            {"ts":1,"group":"g","from":"","to":"A","reason":"initial","level":0,"from_delay":0,"to_delay":41},
            {"ts":2,"group":"g","from":"A","to":"B","reason":"failover","level":1},
            {"ts":3,"group":"g","from":"B","to":"C","reason":"recovery","secret":"must-not-export"},
            {"ts":4,"group":"h","from":"C","to":"D","reason":"faster_same_tier"},
            {"ts":5,"group":"g","from":"C","to":"vless://some-credential","reason":"failover"}
        ])).unwrap()).unwrap();
        let initial = recent(&path, LIMIT, "g", "initial").unwrap();
        assert_eq!(initial.len(), 1);
        assert_eq!(initial[0].new_level, Some(1));
        assert_eq!(initial[0].from_delay_ms, None);
        assert_eq!(initial[0].to_delay_ms, Some(41));
        assert_eq!(recent(&path, 1, "g", "").unwrap()[0].timestamp, 3);
        assert_eq!(
            recent(&path, LIMIT, "h", "faster_same_tier").unwrap().len(),
            1
        );
        assert_eq!(recent(&path, LIMIT, "g", "failover").unwrap().len(), 1);
        let exported = serde_json::to_string(&recent(&path, LIMIT, "", "").unwrap()).unwrap();
        assert!(!exported.contains("must-not-export") && !exported.contains("some-credential"));

        let make_event = |timestamp| Event {
            timestamp,
            group: "g".repeat(380),
            from: "a".repeat(380),
            to: "b".repeat(380),
            check_urls: vec!["https://abcdefgh.example/generate_204".to_owned(); 8],
            ..Event::default()
        };
        append(&path, (10..200).map(make_event).collect()).unwrap();
        let events = recent(&path, 200, "", "").unwrap();
        assert_eq!(events[0].timestamp, 199);
        assert_eq!(events[0].previous_switch_at, Some(198));
        assert!(events.len() <= LIMIT);
        assert!(std::fs::metadata(&path).unwrap().len() <= MAX_BYTES as u64);
        append(&path, vec![make_event(199)]).unwrap();
        assert_eq!(recent(&path, 200, "", "").unwrap().len(), events.len());
    }

    #[test]
    fn corrupt_json_recovers_and_write_failure_does_not_change_observed_state() {
        let dir = TestDir::new();
        let path = dir.0.join("events.json");
        std::fs::write(&path, b"[broken").unwrap();
        assert!(recent(&path, LIMIT, "", "").is_err());

        let mut observer = Observer::default();
        let groups = config();
        assert!(observe(&mut observer, &groups, &proxies("A", "X", false)).is_empty());
        let blocked = dir.0.join("blocked");
        std::fs::create_dir(&blocked).unwrap();
        assert!(
            append(
                &blocked,
                observe(&mut observer, &groups, &proxies("B", "X", true))
            )
            .is_err()
        );
        assert!(observe(&mut observer, &groups, &proxies("B", "X", true)).is_empty());

        append(
            &path,
            observe(&mut observer, &groups, &proxies("A", "X", false)),
        )
        .unwrap();
        let events = recent(&path, LIMIT, "", "").unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!((events[0].from.as_str(), events[0].to.as_str()), ("B", "A"));
        assert!(events[0].previous_switch_at.is_none());
    }

    #[test]
    fn competing_writer_leaves_the_journal_untouched() {
        let dir = TestDir::new();
        let path = dir.0.join("events.json");
        let lock = File::create(path.with_extension("lock")).unwrap();
        lock.try_lock().unwrap();
        let make_event = || Event {
            timestamp: 1,
            group: "priority".into(),
            from: "A".into(),
            to: "B".into(),
            ..Event::default()
        };
        assert!(append(&path, vec![make_event()]).is_err());
        assert!(!path.exists());
        drop(lock);
        append(&path, vec![make_event()]).unwrap();
        assert_eq!(recent(&path, LIMIT, "", "").unwrap().len(), 1);
    }

    #[tokio::test]
    async fn recorder_persists_events_asynchronously_without_blocking_caller() {
        let dir = TestDir::new();
        let path = dir.0.join("events.json");
        let groups = config();
        let recorder = Recorder::spawn(path.clone());

        recorder.observe(
            Arc::clone(&groups),
            (1, 10),
            Instant::now(),
            Source::ClashProxies,
            &proxies("A", "X", false),
        );
        recorder.observe(
            Arc::clone(&groups),
            (1, 10),
            Instant::now(),
            Source::ClashProxies,
            &proxies("B", "X", true),
        );
        recorder.observe(
            Arc::clone(&groups),
            (1, 10),
            Instant::now(),
            Source::ClashProxies,
            &proxies("A", "X", false),
        );

        let mut events = Vec::new();
        for _ in 0..50 {
            if let Ok(found) = recent(&path, LIMIT, "", "")
                && found.len() == 2
            {
                events = found;
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        assert_eq!(events.len(), 2);
        assert_eq!((events[0].from.as_str(), events[0].to.as_str()), ("B", "A"));
        assert_eq!((events[1].from.as_str(), events[1].to.as_str()), ("A", "B"));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn recorder_counts_queue_overflow_and_write_errors() {
        let dir = TestDir::new();
        let path = dir.0.join("events.json");
        let lock = File::create(path.with_extension("lock")).unwrap();
        lock.try_lock().unwrap();
        let recorder = Recorder::spawn(path.clone());
        let groups = config();
        let sample = |i| {
            recorder.observe(
                Arc::clone(&groups),
                (1, 10),
                Instant::now(),
                Source::ClashProxies,
                &proxies(if i % 2 == 0 { "A" } else { "B" }, "X", false),
            );
        };
        // With one executor thread the writer cannot run until we yield below.
        for i in 0..=70 {
            sample(i);
        }
        assert_eq!(recorder.stats().dropped, 6);
        assert_eq!(recorder.stats().written, 0);

        let wait_for = |failure| {
            let recorder = &recorder;
            async move {
                tokio::time::timeout(std::time::Duration::from_secs(3), async {
                    loop {
                        let stats = recorder.stats();
                        if if failure {
                            stats.dropped == 70
                        } else {
                            stats.last_write_at.is_some()
                        } {
                            break;
                        }
                        tokio::task::yield_now().await;
                    }
                })
                .await
                .unwrap();
            }
        };
        wait_for(true).await;
        assert_eq!(recorder.stats().write_errors, 1);
        assert!(!path.exists());
        drop(lock);
        sample(71);
        wait_for(false).await;
        assert_eq!(recorder.stats().written, 1);
        assert_eq!(recent(&path, LIMIT, "", "").unwrap().len(), 1);
    }

    #[test]
    fn append_with_retries_recovers_after_brief_lock_release() {
        let dir = TestDir::new();
        let path = dir.0.join("events.json");
        let lock = File::create(path.with_extension("lock")).unwrap();
        lock.try_lock().unwrap();
        let holder = std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(30));
            drop(lock);
        });
        let event = Event {
            timestamp: 1,
            group: "priority".into(),
            from: "A".into(),
            to: "B".into(),
            ..Event::default()
        };
        append_with_retries(&path, vec![event], 8, std::time::Duration::from_millis(20)).unwrap();
        holder.join().unwrap();
        assert_eq!(recent(&path, LIMIT, "", "").unwrap().len(), 1);
    }

    #[test]
    fn core_last_switch_accepted_for_proxies_and_failover_sequences() {
        let groups = config();
        let mut observer = Observer::default();
        assert!(
            observe(
                &mut observer,
                &groups,
                &json!({"proxies": {"priority": {
                    "now": "A",
                    "switch_generation": "gen-1",
                    "switch_sequence": 1
                }}}),
            )
            .is_empty()
        );

        let evs1 = observe(
            &mut observer,
            &groups,
            &json!({"proxies": {"priority": {
                "now": "B",
                "switch_generation": "gen-1",
                "switch_sequence": 2,
                "last_switch": {
                    "from": "A",
                    "to": "B",
                    "reason": "active_ineligible",
                    "timestamp": 1_795_000_000u64,
                    "trigger": "probe"
                }
            }}}),
        );
        assert_eq!(evs1.len(), 1);
        assert!(evs1[0].reason == Reason::ActiveIneligible);
        assert_eq!(evs1[0].decided_at, Some(1_795_000_000));

        let evs2 = observer
            .transitions(
                Arc::clone(&groups),
                (1, 10),
                Instant::now(),
                Source::CoreFailover,
                &json!({"groups": [{
                    "tag": "priority",
                    "current": "A",
                    "switch_generation": "gen-1",
                    "switch_sequence": 3,
                    "last_switch": {
                        "from": "B",
                        "to": "A",
                        "reason": "higher_priority_eligible",
                        "timestamp": "2026-11-24T06:00:00Z"
                    }
                }]}),
            )
            .unwrap();
        assert_eq!(evs2.len(), 1);
        assert!(evs2[0].reason == Reason::HigherPriorityEligible);
        assert_eq!(evs2[0].decided_at, Some(1_795_500_000));

        let evs3 = observe(
            &mut observer,
            &groups,
            &json!({"proxies": {"priority": {
                "now": "Fast",
                "switch_generation": "gen-1",
                "switch_sequence": 4,
                "last_switch": {
                    "from": "A",
                    "to": "Fast",
                    "reason": "manual_restore",
                    "timestamp": "2026-11-24T09:00:00+03:00"
                }
            }}}),
        );
        assert_eq!(evs3.len(), 1);
        assert!(evs3[0].reason == Reason::ManualRestore);
        assert_eq!(evs3[0].decided_at, Some(1_795_500_000));
    }

    #[test]
    fn core_last_switch_accepts_active_unhealthy_alias() {
        let groups = config();
        let mut observer = Observer::default();
        assert!(
            observe(
                &mut observer,
                &groups,
                &json!({"proxies": {"priority": {"now": "A", "switch_generation": "g1", "switch_sequence": 5}}}),
            )
            .is_empty()
        );
        let evs = observe(
            &mut observer,
            &groups,
            &json!({"proxies": {"priority": {
                "now": "B",
                "switch_generation": "g1",
                "switch_sequence": 6,
                "last_switch": {"from": "A", "to": "B", "reason": "active_unhealthy", "timestamp": 12345}
            }}}),
        );
        assert_eq!(evs.len(), 1);
        assert!(evs[0].reason == Reason::ActiveIneligible);
        assert_eq!(evs[0].decided_at, Some(12345));
    }

    #[test]
    fn core_last_switch_rejected_on_sequence_gap() {
        let groups = config();
        let mut observer = Observer::default();
        observe(
            &mut observer,
            &groups,
            &json!({"proxies": {"priority": {"now": "A", "switch_generation": "g1", "switch_sequence": 1}}}),
        );
        let evs = observe(
            &mut observer,
            &groups,
            &json!({"proxies": {"priority": {
                "now": "B",
                "switch_generation": "g1",
                "switch_sequence": 3,
                "last_switch": {"from": "A", "to": "B", "reason": "manual_restore", "timestamp": 1000}
            }}}),
        );
        assert!(evs[0].reason == Reason::Unknown);
        assert_eq!(evs[0].decided_at, None);
    }

    #[test]
    fn core_last_switch_rejected_on_repeated_sequence() {
        let groups = config();
        let mut observer = Observer::default();
        observe(
            &mut observer,
            &groups,
            &json!({"proxies": {"priority": {"now": "A", "switch_generation": "g1", "switch_sequence": 4}}}),
        );
        let evs = observe(
            &mut observer,
            &groups,
            &json!({"proxies": {"priority": {
                "now": "B",
                "switch_generation": "g1",
                "switch_sequence": 4,
                "last_switch": {"from": "A", "to": "B", "reason": "failover", "timestamp": 1000}
            }}}),
        );
        assert!(evs[0].reason == Reason::Unknown);
        assert_eq!(evs[0].decided_at, None);
    }

    #[test]
    fn core_last_switch_rejected_on_generation_change() {
        let groups = config();
        let mut observer = Observer::default();
        observe(
            &mut observer,
            &groups,
            &json!({"proxies": {"priority": {"now": "A", "switch_generation": "g1", "switch_sequence": 1}}}),
        );
        let evs = observe(
            &mut observer,
            &groups,
            &json!({"proxies": {"priority": {
                "now": "B",
                "switch_generation": "g2",
                "switch_sequence": 2,
                "last_switch": {"from": "A", "to": "B", "reason": "failover", "timestamp": 1000}
            }}}),
        );
        assert!(evs[0].reason == Reason::Unknown);
        assert_eq!(evs[0].decided_at, None);
    }

    #[test]
    fn core_last_switch_rejected_on_from_to_mismatch() {
        let groups = config();
        let mut observer = Observer::default();
        observe(
            &mut observer,
            &groups,
            &json!({"proxies": {"priority": {"now": "A", "switch_generation": "g1", "switch_sequence": 1}}}),
        );
        let evs = observe(
            &mut observer,
            &groups,
            &json!({"proxies": {"priority": {
                "now": "B",
                "switch_generation": "g1",
                "switch_sequence": 2,
                "last_switch": {"from": "Fast", "to": "B", "reason": "failover", "timestamp": 1000}
            }}}),
        );
        assert!(evs[0].reason == Reason::Unknown);
        assert_eq!(evs[0].decided_at, None);
    }

    #[test]
    fn core_last_switch_rejected_on_unknown_reason_code() {
        let groups = config();
        let mut observer = Observer::default();
        observe(
            &mut observer,
            &groups,
            &json!({"proxies": {"priority": {"now": "A", "switch_generation": "g1", "switch_sequence": 1}}}),
        );
        let evs = observe(
            &mut observer,
            &groups,
            &json!({"proxies": {"priority": {
                "now": "B",
                "switch_generation": "g1",
                "switch_sequence": 2,
                "last_switch": {"from": "A", "to": "B", "reason": "future_code", "timestamp": 1000}
            }}}),
        );
        assert!(evs[0].reason == Reason::Unknown);
        assert_eq!(evs[0].decided_at, None);
    }

    #[test]
    fn legacy_core_without_switch_metadata_falls_back_to_unknown() {
        let groups = config();
        let mut observer = Observer::default();
        observe(&mut observer, &groups, &proxies("A", "X", false));
        let evs = observe(&mut observer, &groups, &proxies("B", "X", false));
        assert_eq!(evs.len(), 1);
        assert!(evs[0].reason == Reason::Unknown);
        assert_eq!(evs[0].decided_at, None);
    }

    #[test]
    fn recent_filters_new_reason_codes_and_alias() {
        let dir = TestDir::new();
        let path = dir.0.join("events.json");
        std::fs::write(
            &path,
            serde_json::to_vec(&json!([
                {"ts":1,"group":"g","from":"A","to":"B","reason":"active_ineligible","decided_at":10},
                {"ts":2,"group":"g","from":"B","to":"A","reason":"higher_priority_eligible"},
                {"ts":3,"group":"g","from":"B","to":"A","reason":"manual_restore"}
            ]))
            .unwrap(),
        )
        .unwrap();
        assert_eq!(
            recent(&path, LIMIT, "g", "active_ineligible")
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            recent(&path, LIMIT, "g", "active_unhealthy").unwrap().len(),
            1
        );
        assert_eq!(
            recent(&path, LIMIT, "g", "higher_priority_eligible")
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            recent(&path, LIMIT, "g", "manual_restore").unwrap().len(),
            1
        );
        assert_eq!(recent(&path, LIMIT, "g", "unknown").unwrap().len(), 0);
    }

    #[test]
    fn deserializes_stored_json_without_decided_at_and_with_unhealthy_alias() {
        let ev: Event = serde_json::from_value(json!({
            "timestamp": 10,
            "group": "g",
            "from": "A",
            "to": "B",
            "reason": "active_unhealthy"
        }))
        .unwrap();
        assert!(ev.reason == Reason::ActiveIneligible);
        assert_eq!(ev.decided_at, None);
    }

    #[test]
    fn invalid_decision_timestamp_drops_only_decided_at() {
        let groups = config();
        let mut observer = Observer::default();
        observe(
            &mut observer,
            &groups,
            &json!({"proxies": {"priority": {"now": "A", "switch_generation": "g1", "switch_sequence": 1}}}),
        );
        let evs = observe(
            &mut observer,
            &groups,
            &json!({"proxies": {"priority": {
                "now": "B",
                "switch_generation": "g1",
                "switch_sequence": 2,
                "last_switch": {"from": "A", "to": "B", "reason": "manual_restore", "timestamp": "not-a-time"}
            }}}),
        );
        assert_eq!(evs.len(), 1);
        assert!(evs[0].reason == Reason::ManualRestore);
        assert_eq!(evs[0].decided_at, None);
    }

    #[test]
    fn core_restart_resets_cursor_and_avoids_spurious_transition() {
        let groups = config();
        let mut observer = Observer::default();
        observe(
            &mut observer,
            &groups,
            &json!({"proxies": {"priority": {"now": "A", "switch_generation": "g1", "switch_sequence": 10}}}),
        );
        let after_restart = observer
            .transitions(
                Arc::clone(&groups),
                (2, 20),
                Instant::now(),
                Source::ClashProxies,
                &json!({"proxies": {"priority": {
                    "now": "B",
                    "switch_generation": "g2",
                    "switch_sequence": 1,
                    "last_switch": {"from": "A", "to": "B", "reason": "failover", "timestamp": 1000}
                }}}),
            )
            .unwrap();
        assert!(after_restart.is_empty());
    }
}
