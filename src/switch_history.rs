//! Passive history of selected outbounds. The daemon is the only writer.
use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

use serde::{Deserialize, Serialize};
use serde_json::Value;

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
    } else {
        Some(match reason {
            "initial" => Reason::Initial,
            "failover" => Reason::Failover,
            "recovery" => Reason::Recovery,
            "faster_same_tier" => Reason::FasterSameTier,
            "switch" => Reason::Switch,
            "unknown" => Reason::Unknown,
            _ => return Ok(Vec::new()),
        })
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

fn append(path: &Path, incoming: Vec<Event>) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    // Also serialize a brief overlap during daemon replacement. Never wait for
    // another writer on the path serving the existing Clash response.
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(path.with_extension("lock"))?;
    lock.try_lock()?;
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
    for mut event in incoming {
        if let Some(last) = events.iter().rev().find(|last| last.group == event.group) {
            if (last.timestamp, &last.from, &last.to) == (event.timestamp, &event.from, &event.to) {
                continue;
            }
            event.previous_switch_at = Some(last.timestamp);
        }
        events.push(event);
    }
    events.drain(..events.len().saturating_sub(LIMIT));
    let mut bytes = serde_json::to_vec(&events)?;
    while bytes.len() > MAX_BYTES {
        events.remove(0);
        bytes = serde_json::to_vec(&events)?;
    }
    crate::crypto_gen::write_file_if_changed(path, &bytes)?;
    Ok(())
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

#[derive(Default)]
pub(crate) struct Observer {
    config: Option<Arc<Groups>>,
    core: Option<(u32, u64)>,
    last_sample: Option<Instant>,
    selected: HashMap<String, String>,
}

impl Observer {
    pub(crate) fn observe(
        &mut self,
        config: Arc<Groups>,
        core: (u32, u64),
        started: Instant,
        source: Source,
        snapshot: &Value,
    ) {
        if let Some(events) = self.transitions(config, core, started, source, snapshot)
            && !events.is_empty()
        {
            // A failed write must never change the result of the Clash API request.
            let _ = append(&path(), events);
        }
    }

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
            self.selected.clear();
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
            if self.selected.get(tag).is_some_and(|prev| prev == to) {
                return;
            }
            // The first sample establishes a baseline; it supplies no earlier selection.
            let Some(from) = self.selected.insert(tag.to_owned(), to.to_owned()) else {
                return;
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
                source,
                observed: true,
                priority: Some(group.priority),
                check_urls: group.check_url.clone().into_iter().collect(),
                on_backup: status.get("on_backup").and_then(Value::as_bool),
                primary: primary.map(str::to_owned),
                primary_healthy: primary.and_then(|_| status.get("primary_healthy")?.as_bool()),
                primary_failures: primary.and_then(|_| number(status.get("primary_failures")?)),
                // The endpoints report snapshots with no decision reason.
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
}
