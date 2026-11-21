//! 8-phase atomic Transaction Engine (`PLAN -> PREFLIGHT -> SNAPSHOT -> MUTATE -> VALIDATE -> ACTIVATE -> VERIFY -> COMMIT`),
//! Dry-Run Configuration Planner (`config_plan`), and Last Known Good (`known_good`) snapshot manager.

use std::collections::{HashMap, HashSet};
use std::io::Read as _;
use std::path::Path;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::config_gen;
use crate::crypto_gen;
use crate::store::{
    AppState, RouterStoreData, cidrs_overlap, parse_ipv4_cidr, parse_ipv6_cidr, unix_now_secs,
};

pub const LKG_OBSERVATION_WINDOW_SECS: u64 = 180;

fn valid_cidr_with_slash_v4(raw: &str) -> bool {
    let s = raw.trim();
    s.contains('/') && parse_ipv4_cidr(s).is_some()
}

fn valid_cidr_with_slash_v6(raw: &str) -> bool {
    let s = raw.trim();
    s.contains('/') && parse_ipv6_cidr(s).is_some()
}

fn valid_bool_setting_text(raw: &str) -> bool {
    matches!(
        raw.trim().to_ascii_lowercase().as_str(),
        "0" | "1" | "true" | "false" | "yes" | "no" | "on" | "off"
    )
}

fn validate_fragment_range_value(
    raw: &str,
    min_val: u64,
    suffix_allowed: bool,
    holder_label: &str,
    field_name: &str,
    example: &str,
    errors: &mut Vec<String>,
) {
    let val = raw.trim();
    if val.is_empty() {
        return;
    }
    let clean = if suffix_allowed {
        val.strip_suffix("ms")
            .or_else(|| val.strip_suffix('s'))
            .unwrap_or(val)
    } else {
        val
    };
    let parsed = if let Some((lo_s, hi_s)) = clean.split_once('-') {
        if lo_s.is_empty()
            || hi_s.is_empty()
            || !lo_s.bytes().all(|b| b.is_ascii_digit())
            || !hi_s.bytes().all(|b| b.is_ascii_digit())
        {
            None
        } else {
            lo_s.parse::<u64>().ok().zip(hi_s.parse::<u64>().ok())
        }
    } else if clean.bytes().all(|b| b.is_ascii_digit()) {
        clean.parse::<u64>().ok().map(|n| (n, n))
    } else {
        None
    };

    let Some((lo, hi)) = parsed else {
        errors.push(format!(
            "{holder_label} has invalid {field_name} '{val}'. Expected e.g. '{example}'."
        ));
        return;
    };
    if lo < min_val || hi < lo {
        errors.push(format!(
            "{holder_label} has invalid {field_name} '{val}' (range bounds out of order)."
        ));
    }
}

fn validate_source_fragment_options(
    tls_fragment_mode: &str,
    tcp_fragment_length: &str,
    tcp_fragment_delay: &str,
    holder_label: &str,
    errors: &mut Vec<String>,
) {
    let mode = tls_fragment_mode.trim().to_ascii_lowercase();
    if !mode.is_empty()
        && !matches!(
            mode.as_str(),
            "tls_record" | "tls_fragment" | "tcp_fragment"
        )
    {
        errors.push(format!(
            "{holder_label} has invalid tls_fragment_mode '{mode}'. Expected tls_record, tls_fragment, or tcp_fragment."
        ));
    }
    validate_fragment_range_value(
        tcp_fragment_length,
        1,
        false,
        holder_label,
        "tcp_fragment_length",
        "20-60",
        errors,
    );
    validate_fragment_range_value(
        tcp_fragment_delay,
        0,
        true,
        holder_label,
        "tcp_fragment_delay",
        "0-2ms",
        errors,
    );
}

fn validate_local_ruleset_file(
    raw_ref: &str,
    owner_label: &str,
    field_name: &str,
    errors: &mut Vec<String>,
) {
    let clean = raw_ref.trim();
    if clean.is_empty()
        || config_gen::is_remote_ruleset_url(clean)
        || config_gen::is_community_list_token(clean)
        || !config_gen::is_local_ruleset_path(clean)
    {
        return;
    }

    let path = Path::new(clean);
    let mut file = match std::fs::File::open(path) {
        Ok(f) => f,
        Err(e) => {
            errors.push(format!(
                "{owner_label} {field_name} references local rule-set '{clean}' which does not exist or is unreadable: {e}"
            ));
            return;
        }
    };
    let meta = match file.metadata() {
        Ok(m) => m,
        Err(e) => {
            errors.push(format!(
                "{owner_label} {field_name} local rule-set '{clean}' metadata could not be read: {e}"
            ));
            return;
        }
    };
    if !meta.is_file() {
        errors.push(format!(
            "{owner_label} {field_name} local rule-set '{clean}' is not a regular file"
        ));
        return;
    }

    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|s| s.to_ascii_lowercase());
    match ext.as_deref() {
        Some("json") => {
            if meta.len() == 0 {
                errors.push(format!(
                    "{owner_label} {field_name} local JSON rule-set '{clean}' is empty"
                ));
                return;
            }
            let parsed: Value = match serde_json::from_reader(std::io::BufReader::new(file)) {
                Ok(v) => v,
                Err(e) => {
                    errors.push(format!(
                        "{owner_label} {field_name} local JSON rule-set '{clean}' is invalid JSON: {e}"
                    ));
                    return;
                }
            };
            if !parsed
                .as_object()
                .is_some_and(|obj| obj.get("rules").is_some_and(Value::is_array))
            {
                errors.push(format!(
                    "{owner_label} {field_name} local JSON rule-set '{clean}' must be a JSON object containing a 'rules' array"
                ));
            }
        }
        Some("trs") | Some("tsr") => {
            if meta.len() == 0 {
                errors.push(format!(
                    "{owner_label} {field_name} local .trs rule-set '{clean}' is empty"
                ));
                return;
            }
            if meta.len() < 16 {
                errors.push(format!(
                    "{owner_label} {field_name} local .trs rule-set '{clean}' is truncated ({} bytes; expected >= 16 bytes with TRS/TSRS/TCRS header)",
                    meta.len()
                ));
                return;
            }
            let mut hdr = [0u8; 4];
            if let Err(e) = file.read_exact(&mut hdr) {
                errors.push(format!(
                    "{owner_label} {field_name} local .trs rule-set '{clean}' could not read header: {e}"
                ));
                return;
            }
            if !(hdr.starts_with(b"TRS") || hdr == *b"TSRS" || hdr == *b"TCRS") {
                errors.push(format!(
                    "{owner_label} {field_name} local .trs rule-set '{clean}' has invalid TRS magic/header"
                ));
            }
        }
        Some("srs") => {
            if meta.len() == 0 {
                errors.push(format!(
                    "{owner_label} {field_name} local .srs rule-set '{clean}' is empty"
                ));
                return;
            }
            if meta.len() < 16 {
                errors.push(format!(
                    "{owner_label} {field_name} local .srs rule-set '{clean}' is truncated ({} bytes; expected >= 16 bytes with SRS header)",
                    meta.len()
                ));
                return;
            }
            let mut hdr = [0u8; 4];
            if let Err(e) = file.read_exact(&mut hdr) {
                errors.push(format!(
                    "{owner_label} {field_name} local .srs rule-set '{clean}' could not read header: {e}"
                ));
                return;
            }
            if !hdr.starts_with(b"SRS") {
                errors.push(format!(
                    "{owner_label} {field_name} local .srs rule-set '{clean}' has invalid SRS magic/header"
                ));
            }
        }
        Some("txt") | Some("lst") => {
            let mut buf = String::new();
            if let Err(e) = file.read_to_string(&mut buf) {
                errors.push(format!(
                    "{owner_label} {field_name} local plain rule-set '{clean}' is not valid UTF-8 text: {e}"
                ));
            }
        }
        _ => {}
    }
}

fn validate_condition_local_rulesets<'a>(
    cond: &'a crate::store::TrafficCondition,
    cond_map: &HashMap<&'a str, &'a crate::store::TrafficCondition>,
    visited: &mut HashSet<&'a str>,
    errors: &mut Vec<String>,
) {
    if !cond.enabled || !visited.insert(cond.id.as_str()) {
        return;
    }
    let label = format!("Condition '{}'", cond.id);
    for r in &cond.rule_set {
        validate_local_ruleset_file(r, &label, "rule_set", errors);
    }
    for r in &cond.rule_set_with_subnets {
        validate_local_ruleset_file(r, &label, "rule_set_with_subnets", errors);
    }
    for child_id in &cond.children {
        if let Some(child) = cond_map.get(child_id.trim()).copied() {
            validate_condition_local_rulesets(child, cond_map, visited, errors);
        }
    }
}

fn validate_local_ruleset_paths(candidate: &RouterStoreData, errors: &mut Vec<String>) {
    let cond_map: HashMap<&str, &crate::store::TrafficCondition> = candidate
        .conditions
        .iter()
        .map(|c| (c.id.as_str(), c))
        .collect();
    let mut visited_conds: HashSet<&str> = HashSet::new();

    for sec in candidate.sections.iter().filter(|s| s.enabled) {
        let label = format!("Section '{}'", sec.id);
        for r in &sec.rule_set_urls {
            validate_local_ruleset_file(r, &label, "rule_set_urls", errors);
        }
        for r in &sec.rule_set_with_subnets {
            validate_local_ruleset_file(r, &label, "rule_set_with_subnets", errors);
        }
        for cref in &sec.condition_refs {
            if let Some(cond) = cond_map.get(cref.trim()).copied() {
                validate_condition_local_rulesets(cond, &cond_map, &mut visited_conds, errors);
            }
        }
    }

    for cond in candidate.conditions.iter().filter(|c| c.enabled) {
        validate_condition_local_rulesets(cond, &cond_map, &mut visited_conds, errors);
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConfigPlanReport {
    pub valid: bool,
    pub restart_impact: String,
    pub errors: Vec<String>,
    pub warnings: Vec<String>,
    pub summary: Value,
}

/// Validate semantic integrity of `RouterStoreData` (port collisions, dangling references,
/// rule shadowing, and server section cascade invariants).
pub fn analyze_config_plan(candidate: &RouterStoreData) -> ConfigPlanReport {
    let mut errors = Vec::new();
    let mut warnings = Vec::new();

    let cond_ids: HashSet<&str> = candidate.conditions.iter().map(|c| c.id.as_str()).collect();
    let src_ids: HashSet<&str> = candidate
        .outbound_sources
        .iter()
        .map(|s| s.id.as_str())
        .collect();
    let bal_ids: HashSet<&str> = candidate.balancers.iter().map(|b| b.id.as_str()).collect();
    let grp_ids: HashSet<&str> = candidate
        .outbound_groups
        .iter()
        .map(|g| g.id.as_str())
        .collect();

    for sec in &candidate.sections {
        for cref in &sec.condition_refs {
            if !cond_ids.contains(cref.as_str()) {
                errors.push(format!(
                    "Section '{}' references missing condition '{}'",
                    sec.id, cref
                ));
            }
        }
        for sref in &sec.outbound_source_refs {
            if !src_ids.contains(sref.as_str()) {
                errors.push(format!(
                    "Section '{}' references missing outbound_source '{}'",
                    sec.id, sref
                ));
            }
        }
        for bref in &sec.balancer_refs {
            if !bal_ids.contains(bref.as_str()) {
                errors.push(format!(
                    "Section '{}' references missing balancer '{}'",
                    sec.id, bref
                ));
            }
        }
        if !sec.outbound_group_ref.is_empty() && !grp_ids.contains(sec.outbound_group_ref.as_str())
        {
            errors.push(format!(
                "Section '{}' references missing outbound_group '{}'",
                sec.id, sec.outbound_group_ref
            ));
        }
        let raw_v6_sup = sec.ipv6_support.trim().to_ascii_lowercase();
        if !raw_v6_sup.is_empty() && raw_v6_sup != "auto" && !valid_bool_setting_text(&raw_v6_sup) {
            errors.push(format!(
                "Section '{}' has invalid ipv6_support '{}' (expected auto, 0, or 1)",
                sec.id, sec.ipv6_support
            ));
        }
        if sec.enabled
            && matches!(
                sec.connection_type.as_str(),
                "proxy" | "desync" | "wdtt" | "fptn" | "tailscale"
            )
            && sec.outbound_source_refs.is_empty()
            && sec.outbound_group_ref.is_empty()
        {
            warnings.push(format!(
                "Section '{}' ({}) has no outbound sources assigned; will fallback to built-in default",
                sec.label, sec.connection_type
            ));
        }
    }

    // Check inbound server port collisions and Tailscale network options
    let mut used_ports: HashSet<u16> = HashSet::new();
    used_ports.insert(candidate.settings.listen_port);
    used_ports.insert(1602);
    for srv in candidate.servers.iter().filter(|s| s.enabled) {
        if srv.is_tailscale() {
            if let Err(msg) = crate::store::validate_tailscale_network_options(
                &srv.tailscale_relay_server_port,
                &srv.tailscale_system_interface_mtu,
                &format!("Server '{}'", srv.id),
            ) {
                errors.push(msg);
            }
            continue;
        }
        if srv.listen_port == 0 {
            errors.push(format!("Inbound server '{}' has invalid port 0", srv.id));
        } else if !used_ports.insert(srv.listen_port) {
            errors.push(format!(
                "Port collision detected on port {} (inbound server '{}')",
                srv.listen_port, srv.label
            ));
        }
    }

    for sec in candidate.sections.iter().filter(|s| s.enabled) {
        if sec.mixed_proxy_enabled
            && sec.mixed_proxy_port > 0
            && !used_ports.insert(sec.mixed_proxy_port)
        {
            warnings.push(format!(
                "Section '{}' mixed_proxy_port {} conflicts with another enabled inbound/section and will be skipped",
                sec.id, sec.mixed_proxy_port
            ));
        }
        if sec.is_tailscale()
            && let Err(msg) = crate::store::validate_tailscale_network_options(
                &sec.tailscale_relay_server_port,
                &sec.tailscale_system_interface_mtu,
                &format!("Section '{}'", sec.id),
            )
        {
            errors.push(msg);
        }
    }

    for src in candidate.outbound_sources.iter().filter(|s| s.enabled) {
        let stype = src.source_type.trim().to_ascii_lowercase();
        if stype == "tailscale"
            && let Err(msg) = crate::store::validate_tailscale_network_options(
                &src.tailscale_relay_server_port,
                &src.tailscale_system_interface_mtu,
                &format!("Tailscale source '{}'", src.id),
            )
        {
            errors.push(msg);
        }
        if matches!(stype.as_str(), "subscription" | "proxy_links") {
            validate_source_fragment_options(
                &src.tls_fragment_mode,
                &src.tcp_fragment_length,
                &src.tcp_fragment_delay,
                &format!("Outbound source '{}'", src.id),
                &mut errors,
            );
        }
    }

    let fakeip4 = candidate.settings.fakeip_inet4_range.trim();
    if !fakeip4.is_empty() && !valid_cidr_with_slash_v4(fakeip4) {
        errors.push(format!("Invalid FakeIPv4 CIDR range '{fakeip4}'"));
    }
    let fakeip6 = candidate.settings.fakeip_inet6_range.trim();
    if !fakeip6.is_empty() && !valid_cidr_with_slash_v6(fakeip6) {
        errors.push(format!("Invalid FakeIPv6 CIDR range '{fakeip6}'"));
    }
    let tun4 = candidate.settings.tun_inet4.trim();
    if !tun4.is_empty() && !valid_cidr_with_slash_v4(tun4) {
        errors.push(format!("Invalid TUN IPv4 CIDR '{tun4}'"));
    }
    let tun6 = candidate.settings.tun_inet6.trim();
    if !tun6.is_empty() && !valid_cidr_with_slash_v6(tun6) {
        errors.push(format!("Invalid TUN IPv6 CIDR '{tun6}'"));
    }

    let eff_fakeip4 = if fakeip4.is_empty() {
        "198.18.0.0/15"
    } else {
        fakeip4
    };
    let eff_fakeip6 = if fakeip6.is_empty() {
        "fc00::/18"
    } else {
        fakeip6
    };
    if !tun4.is_empty()
        && valid_cidr_with_slash_v4(tun4)
        && valid_cidr_with_slash_v4(eff_fakeip4)
        && cidrs_overlap(tun4, eff_fakeip4)
    {
        errors.push(format!(
            "TUN IPv4 CIDR '{tun4}' overlaps FakeIPv4 range '{eff_fakeip4}'"
        ));
    }
    if !tun6.is_empty()
        && valid_cidr_with_slash_v6(tun6)
        && valid_cidr_with_slash_v6(eff_fakeip6)
        && cidrs_overlap(tun6, eff_fakeip6)
    {
        errors.push(format!(
            "TUN IPv6 CIDR '{tun6}' overlaps FakeIPv6 range '{eff_fakeip6}'"
        ));
    }

    validate_local_ruleset_paths(candidate, &mut errors);

    // Validate compiled `tachyon-core` JSON generation
    if let Err(e) = config_gen::compile_core_config(candidate) {
        errors.push(format!("Core config compilation error: {e}"));
    }

    ConfigPlanReport {
        valid: errors.is_empty(),
        restart_impact: "hot_reload".to_string(),
        errors,
        warnings,
        summary: json!({
            "sections_total": candidate.sections.len(),
            "sections_enabled": candidate.sections.iter().filter(|s| s.enabled).count(),
            "conditions_total": candidate.conditions.len(),
            "outbound_sources_total": candidate.outbound_sources.len(),
            "balancers_total": candidate.balancers.len(),
            "servers_enabled": candidate.servers.iter().filter(|s| s.enabled).count(),
            "profiles_enabled": candidate.profiles.iter().filter(|p| p.enabled).count(),
            "schedules_enabled": candidate.schedules.iter().filter(|s| s.enabled).count(),
        }),
    }
}

/// Enforce the server-section cascade rule from `08_UCI_CONFIGURATION_SCHEMA.md`:
/// disabling a routing section also disables enabled inbound servers with
/// `routing_mode == "section"` and matching `routing_section`.
pub fn enforce_section_server_cascade(data: &mut RouterStoreData) {
    let disabled_sections: HashSet<String> = data
        .sections
        .iter()
        .filter(|s| !s.enabled)
        .map(|s| s.id.clone())
        .collect();

    for srv in &mut data.servers {
        if srv.enabled
            && srv.routing_mode == "section"
            && disabled_sections.contains(&srv.routing_section)
        {
            srv.enabled = false;
        }
    }
}

/// Capture current working `RouterStoreData` into the Last Known Good (`tachyon.known_good.json`) snapshot.
pub fn promote_to_known_good(lkg_path: &Path, data: &RouterStoreData) -> anyhow::Result<bool> {
    crypto_gen::write_json_if_changed(lkg_path, data)
}

/// Clone `RouterStoreData` onto the heap without keeping temporary stack copies in async futures.
#[inline(never)]
fn clone_store_boxed(src: &RouterStoreData) -> Box<RouterStoreData> {
    Box::new(src.clone())
}

/// Restore heap-allocated `Box<RouterStoreData>` from Last Known Good (`tachyon.known_good.json`).
#[inline(never)]
pub fn load_known_good_boxed(lkg_path: &Path) -> anyhow::Result<Box<RouterStoreData>> {
    let raw = std::fs::read_to_string(lkg_path)?;
    Ok(serde_json::from_str::<Box<RouterStoreData>>(&raw)?)
}

/// Restore `RouterStoreData` from Last Known Good (`tachyon.known_good.json`) if available.
pub fn load_known_good(lkg_path: &Path) -> anyhow::Result<RouterStoreData> {
    Ok(*load_known_good_boxed(lkg_path)?)
}

/// Execute an 8-phase atomic configuration transaction with LIFO rollback on failure,
/// recording a structural history entry with the supplied `source` tag into `hist_dir`.
#[inline(never)]
pub fn commit_transaction_boxed_in_history_dir<'a>(
    state: &'a Arc<AppState>,
    candidate: Box<RouterStoreData>,
    source: &'a str,
    hist_dir: Option<std::path::PathBuf>,
) -> std::pin::Pin<
    Box<dyn std::future::Future<Output = anyhow::Result<ConfigPlanReport>> + Send + 'a>,
> {
    Box::pin(async move {
        let mut candidate = candidate;

        // Phase 1: PLAN (deduplicate cloned conditions and enforce cascade invariants)
        candidate.deduplicate_cloned_conditions();
        enforce_section_server_cascade(&mut candidate);

        // Phase 2: PREFLIGHT & Phase 5: VALIDATE
        let plan = analyze_config_plan(&candidate);
        if !plan.valid {
            anyhow::bail!("Transaction validation failed: {}", plan.errors.join("; "));
        }

        // Phase 3: SNAPSHOT (capture current state on heap for instant LIFO rollback)
        let mut previous = {
            let guard = state.data.read().await;
            clone_store_boxed(&guard)
        };
        if !state.lkg_path.exists() {
            let _ = promote_to_known_good(&state.lkg_path, &previous);
        }

        // Phase 4: MUTATE (write compiled core config + store JSON using NAND-safe atomic writers)
        {
            let core_cfg = config_gen::compile_core_config(&candidate)?;
            let core_cfg_path = Path::new(&candidate.settings.core_config_path);
            if let Err(e) = crypto_gen::write_json_if_changed(core_cfg_path, &core_cfg) {
                // Non-fatal on dev hosts where `/etc/tachyon-core` is not writable; fallback to local data dir
                if let Some(parent) = state.path.parent() {
                    let fallback_core = parent.join("tachyon-core-config.json");
                    crypto_gen::write_json_if_changed(&fallback_core, &core_cfg)
                        .map_err(|fe| anyhow::anyhow!("Failed writing core config ({e} / {fe})"))?;
                }
            }
        }

        {
            let mut d = state.data.write().await;
            std::mem::swap(&mut *d, &mut *candidate);
        }
        drop(candidate);

        if let Err(e) = state.save().await {
            // LIFO Rollback
            let mut d = state.data.write().await;
            std::mem::swap(&mut *d, &mut *previous);
            anyhow::bail!("Transaction commit failed, rolled back in-memory state: {e}");
        }

        let recorded_id = {
            let committed = state.data.read().await;
            match hist_dir.as_deref() {
                Some(dir) => crate::config_history::record_commit_revision_in(
                    dir, &previous, &committed, source,
                ),
                None => {
                    crate::config_history::record_commit_revision(&previous, &committed, source)
                }
            }
            .map(|s| s.id)
        };
        drop(previous);

        // Phase 6-8: ACTIVATE & COMMIT (start LKG 180s observation window unless auto_rollback)
        {
            let mut live = state.live.write().await;
            if let Some(id) = recorded_id {
                live.active_revision_id = id;
            }
            if source == "auto_rollback" {
                live.lkg_observing = false;
                live.lkg_remaining_secs = 0;
                live.push_event(
                    "warn",
                    "transaction",
                    &format!("Committed automatic rollback at {}", unix_now_secs()),
                );
            } else {
                live.lkg_observing = true;
                live.lkg_remaining_secs = LKG_OBSERVATION_WINDOW_SECS;
                live.push_event(
                    "info",
                    "transaction",
                    &format!(
                        "Committed transaction at {} (LKG observation window: {}s)",
                        unix_now_secs(),
                        LKG_OBSERVATION_WINDOW_SECS
                    ),
                );
            }
        }

        Ok(plan)
    })
}

/// Execute an 8-phase atomic configuration transaction with LIFO rollback on failure,
/// taking a heap-allocated `Box<RouterStoreData>` to keep async task frames small on 512 KiB stacks.
#[inline(never)]
pub fn commit_transaction_boxed<'a>(
    state: &'a Arc<AppState>,
    candidate: Box<RouterStoreData>,
    source: &'a str,
) -> std::pin::Pin<
    Box<dyn std::future::Future<Output = anyhow::Result<ConfigPlanReport>> + Send + 'a>,
> {
    commit_transaction_boxed_in_history_dir(state, candidate, source, None)
}

/// Execute an 8-phase atomic configuration transaction with LIFO rollback on failure,
/// recording a structural history entry with the supplied `source` tag.
#[allow(dead_code)]
pub async fn commit_transaction_with_source(
    state: &Arc<AppState>,
    candidate: RouterStoreData,
    source: &str,
) -> anyhow::Result<ConfigPlanReport> {
    commit_transaction_boxed(state, Box::new(candidate), source).await
}

/// Execute an 8-phase atomic configuration transaction with LIFO rollback on failure.
pub async fn commit_transaction(
    state: &Arc<AppState>,
    candidate: RouterStoreData,
) -> anyhow::Result<ConfigPlanReport> {
    commit_transaction_boxed(state, Box::new(candidate), "save").await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::{InboundServer, OutboundSource};

    #[test]
    fn test_section_disable_cascades_to_bound_server() {
        let mut data = RouterStoreData::default();
        data.sections[0].id = "sec_main".to_string();
        data.sections[0].enabled = false;
        data.servers.push(InboundServer {
            id: "srv1".to_string(),
            enabled: true,
            label: "Guest Server".to_string(),
            protocol: "vless".to_string(),
            listen: "0.0.0.0".to_string(),
            listen_port: 8443,
            routing_mode: "section".to_string(),
            routing_section: "sec_main".to_string(),
            ..Default::default()
        });
        enforce_section_server_cascade(&mut data);
        assert!(!data.servers[0].enabled);
    }

    #[test]
    fn test_analyze_config_plan_cidr_overlap_and_syntax() {
        let mut data = RouterStoreData::default();
        data.settings.tun_inet4 = "172.19.0.1/30".to_string();
        data.settings.fakeip_inet4_range = "198.18.0.0/15".to_string();
        data.settings.tun_inet6 = "fdfe:dcba:9876::1/126".to_string();
        data.settings.fakeip_inet6_range = "fc00::/18".to_string();
        let baseline = analyze_config_plan(&data);
        assert!(baseline.valid, "unexpected errors: {:?}", baseline.errors);

        // Bare IPs without /prefix must be rejected
        let mut bare_fakeip4 = data.clone();
        bare_fakeip4.settings.fakeip_inet4_range = "198.18.0.0".to_string();
        let report = analyze_config_plan(&bare_fakeip4);
        assert!(!report.valid);
        assert!(
            report
                .errors
                .iter()
                .any(|e| e.contains("Invalid FakeIPv4 CIDR range"))
        );

        let mut bad_fakeip6 = data.clone();
        bad_fakeip6.settings.fakeip_inet6_range = "fc00::/129".to_string();
        let report = analyze_config_plan(&bad_fakeip6);
        assert!(!report.valid);
        assert!(
            report
                .errors
                .iter()
                .any(|e| e.contains("Invalid FakeIPv6 CIDR range"))
        );

        let mut bad_tun4 = data.clone();
        bad_tun4.settings.tun_inet4 = "999.0.0.1/24".to_string();
        let report = analyze_config_plan(&bad_tun4);
        assert!(!report.valid);
        assert!(
            report
                .errors
                .iter()
                .any(|e| e.contains("Invalid TUN IPv4 CIDR"))
        );

        let mut bad_tun6 = data.clone();
        bad_tun6.settings.tun_inet6 = "not-an-ipv6".to_string();
        let report = analyze_config_plan(&bad_tun6);
        assert!(!report.valid);
        assert!(
            report
                .errors
                .iter()
                .any(|e| e.contains("Invalid TUN IPv6 CIDR"))
        );

        // Explicit IPv4 overlap
        let mut overlap4 = data.clone();
        overlap4.settings.tun_inet4 = "198.19.0.1/30".to_string();
        let report = analyze_config_plan(&overlap4);
        assert!(!report.valid);
        assert!(
            report
                .errors
                .iter()
                .any(|e| e.contains("overlaps FakeIPv4 range"))
        );

        // Default FakeIPv4 fallback (empty fakeip_inet4_range -> 198.18.0.0/15) still detects overlap
        let mut overlap4_default = data.clone();
        overlap4_default.settings.fakeip_inet4_range.clear();
        overlap4_default.settings.tun_inet4 = "198.18.42.1/30".to_string();
        let report = analyze_config_plan(&overlap4_default);
        assert!(!report.valid);
        assert!(
            report
                .errors
                .iter()
                .any(|e| e.contains("overlaps FakeIPv4 range '198.18.0.0/15'"))
        );

        // Explicit IPv6 overlap
        let mut overlap6 = data.clone();
        overlap6.settings.tun_inet6 = "fc00:10::1/126".to_string();
        let report = analyze_config_plan(&overlap6);
        assert!(!report.valid);
        assert!(
            report
                .errors
                .iter()
                .any(|e| e.contains("overlaps FakeIPv6 range"))
        );

        // Default FakeIPv6 fallback (empty fakeip_inet6_range -> fc00::/18) still detects overlap
        let mut overlap6_default = data.clone();
        overlap6_default.settings.fakeip_inet6_range.clear();
        overlap6_default.settings.tun_inet6 = "fc00:200::1/126".to_string();
        let report = analyze_config_plan(&overlap6_default);
        assert!(!report.valid);
        assert!(
            report
                .errors
                .iter()
                .any(|e| e.contains("overlaps FakeIPv6 range 'fc00::/18'"))
        );
    }

    #[test]
    fn test_analyze_config_plan_validates_section_ipv6_support() {
        let mut data = RouterStoreData::default();
        for valid_val in ["", "auto", "true", "false", "0", "1", "on", "off"] {
            data.sections[0].ipv6_support = valid_val.to_string();
            let report = analyze_config_plan(&data);
            assert!(
                !report.errors.iter().any(|e| e.contains("ipv6_support")),
                "unexpected ipv6_support error for '{valid_val}': {:?}",
                report.errors
            );
        }

        data.sections[0].ipv6_support = "prefer_v6".to_string();
        let report = analyze_config_plan(&data);
        assert!(!report.valid);
        assert!(
            report
                .errors
                .iter()
                .any(|e| e.contains("invalid ipv6_support"))
        );
    }

    #[tokio::test]
    async fn test_commit_transaction_deduplicates_cloned_conditions() {
        use crate::store::{RoutingSection, TrafficCondition};

        let tmp_dir = std::env::temp_dir().join(format!(
            "tachyon_tx_dedup_{}_{}",
            std::process::id(),
            unix_now_secs()
        ));
        let _ = std::fs::create_dir_all(&tmp_dir);
        let store_path = tmp_dir.join("store.json");
        let core_path = tmp_dir.join("tachyon-core-config.json");

        let state = AppState::load_or_create(&store_path).expect("load_or_create");
        let mut candidate = RouterStoreData::default();
        candidate.settings.core_config_path = core_path.to_string_lossy().into_owned();
        candidate.settings.tun_inet4 = "172.19.0.1/30".to_string();
        candidate.settings.fakeip_inet4_range = "198.18.0.0/15".to_string();
        candidate.settings.tun_inet6 = "fdfe:dcba:9876::1/126".to_string();
        candidate.settings.fakeip_inet6_range = "fc00::/18".to_string();

        let base_cond = TrafficCondition {
            id: "cond_dup_base".to_string(),
            enabled: true,
            name: "Base Rule".to_string(),
            condition_type: "atomic".to_string(),
            user_domains: vec!["example.org".to_string()],
            community_subnets: true,
            ..Default::default()
        };
        let mut clone_cond = base_cond.clone();
        clone_cond.id = "cond_dup_base_copy".to_string();

        let before_count = candidate.conditions.len();
        candidate.conditions.push(base_cond);
        candidate.conditions.push(clone_cond);
        candidate.sections.push(RoutingSection {
            id: "sec_dedup_test".to_string(),
            enabled: true,
            label: "Dedup Direct".to_string(),
            connection_type: "direct".to_string(),
            action: "direct".to_string(),
            condition_refs: vec!["cond_dup_base_copy".to_string()],
            condition_expression: "cond_dup_base_copy".to_string(),
            ipv6_support: "auto".to_string(),
            ..Default::default()
        });

        let report = commit_transaction(&state, candidate)
            .await
            .expect("commit_transaction should succeed");
        assert!(report.valid);
        assert_eq!(
            report.summary["conditions_total"].as_u64(),
            Some((before_count + 1) as u64)
        );

        let committed = state.data.read().await;
        assert!(committed.conditions.iter().any(|c| c.id == "cond_dup_base"));
        assert!(
            !committed
                .conditions
                .iter()
                .any(|c| c.id == "cond_dup_base_copy")
        );
        let sec = committed
            .sections
            .iter()
            .find(|s| s.id == "sec_dedup_test")
            .expect("sec_dedup_test present");
        assert_eq!(sec.condition_refs, vec!["cond_dup_base"]);
        assert_eq!(sec.condition_expression, "cond_dup_base");
        drop(committed);

        let _ = std::fs::remove_dir_all(&tmp_dir);
    }

    #[test]
    fn test_source_fragment_options_validation() {
        let mut ok_store = RouterStoreData::default();
        ok_store.outbound_sources.push(OutboundSource {
            id: "sub_frag_ok".to_string(),
            enabled: true,
            source_type: "subscription".to_string(),
            tls_fragment_mode: "tcp_fragment".to_string(),
            tcp_fragment_length: "20-60".to_string(),
            tcp_fragment_delay: "0-2ms".to_string(),
            ..Default::default()
        });
        let report_ok = analyze_config_plan(&ok_store);
        assert!(report_ok.valid, "unexpected errors: {:?}", report_ok.errors);

        let mut bad_store = RouterStoreData::default();
        bad_store.outbound_sources.push(OutboundSource {
            id: "sub_frag_bad".to_string(),
            enabled: true,
            source_type: "proxy_links".to_string(),
            tls_fragment_mode: "bogus_mode".to_string(),
            tcp_fragment_length: "60-20".to_string(),
            tcp_fragment_delay: "bad".to_string(),
            ..Default::default()
        });
        let report_bad = analyze_config_plan(&bad_store);
        assert!(!report_bad.valid);
        let joined = report_bad.errors.join("\n");
        assert!(joined.contains("tls_fragment_mode"));
        assert!(joined.contains("tcp_fragment_length"));
        assert!(joined.contains("tcp_fragment_delay"));
    }

    #[test]
    fn test_analyze_config_plan_validates_local_ruleset_files() {
        use crate::store::{RoutingSection, TrafficCondition};

        let tmp_dir = std::env::temp_dir().join(format!(
            "tachyon_tx_rs_val_{}_{}",
            std::process::id(),
            crate::crypto_gen::generate_hex(4)
        ));
        std::fs::create_dir_all(&tmp_dir).expect("create temp dir");

        let valid_json = tmp_dir.join("valid.json");
        std::fs::write(&valid_json, r#"{"version":3,"rules":[{"domain":["example.com"]}]}"#)
            .unwrap();

        let malformed_json = tmp_dir.join("malformed.json");
        std::fs::write(&malformed_json, b"{broken").unwrap();

        let no_rules_json = tmp_dir.join("no_rules.json");
        std::fs::write(&no_rules_json, r#"{"version":3}"#).unwrap();

        let wrong_rules_type_json = tmp_dir.join("wrong_rules.json");
        std::fs::write(&wrong_rules_type_json, r#"{"version":3,"rules":"not-array"}"#).unwrap();

        let valid_trs = tmp_dir.join("valid.trs");
        let mut trs_bytes = b"TSRS".to_vec();
        trs_bytes.resize(32, 0x01);
        std::fs::write(&valid_trs, &trs_bytes).unwrap();

        let empty_trs = tmp_dir.join("empty.trs");
        std::fs::write(&empty_trs, b"").unwrap();

        let short_trs = tmp_dir.join("short.trs");
        std::fs::write(&short_trs, b"TSRS").unwrap();

        let bad_magic_trs = tmp_dir.join("bad_magic.trs");
        std::fs::write(&bad_magic_trs, b"BADMAGIC_1234567890").unwrap();

        let valid_srs = tmp_dir.join("valid.srs");
        let srs_bytes = b"\x53\x52\x53\x02\x78\xda\x62\x00\x04\x00\x00\xff\xff\x00\x01\x00\x01";
        std::fs::write(&valid_srs, srs_bytes).unwrap();

        let empty_srs = tmp_dir.join("empty.srs");
        std::fs::write(&empty_srs, b"").unwrap();

        let short_srs = tmp_dir.join("short.srs");
        std::fs::write(&short_srs, b"SRS\x02tiny").unwrap();

        let bad_magic_srs = tmp_dir.join("bad_magic.srs");
        std::fs::write(&bad_magic_srs, b"NOT_SRS_1234567890").unwrap();

        let missing_json = tmp_dir.join("missing.json");

        // 1. Valid local JSON + .trs + .srs + remote URLs + plain built-in tokens + disabled missing file pass
        let ok_store = RouterStoreData {
            sections: vec![
                RoutingSection {
                    id: "sec_ok".to_string(),
                    enabled: true,
                    action: "direct".to_string(),
                    connection_type: "direct".to_string(),
                    rule_set_urls: vec![
                        valid_json.to_string_lossy().into_owned(),
                        "https://example.com/remote.trs".to_string(),
                        "youtube".to_string(),
                    ],
                    rule_set_with_subnets: vec![
                        valid_srs.to_string_lossy().into_owned(),
                        "http://example.com/list.json".to_string(),
                        "refilter".to_string(),
                    ],
                    condition_refs: vec!["cond_parent".to_string()],
                    ..Default::default()
                },
                RoutingSection {
                    id: "sec_disabled".to_string(),
                    enabled: false,
                    action: "direct".to_string(),
                    connection_type: "direct".to_string(),
                    rule_set_urls: vec![missing_json.to_string_lossy().into_owned()],
                    ..Default::default()
                },
            ],
            conditions: vec![
                TrafficCondition {
                    id: "cond_child".to_string(),
                    enabled: true,
                    condition_type: "atomic".to_string(),
                    rule_set: vec![valid_trs.to_string_lossy().into_owned()],
                    rule_set_with_subnets: vec![valid_json.to_string_lossy().into_owned()],
                    ..Default::default()
                },
                TrafficCondition {
                    id: "cond_parent".to_string(),
                    enabled: true,
                    condition_type: "all".to_string(),
                    children: vec!["cond_child".to_string()],
                    ..Default::default()
                },
                TrafficCondition {
                    id: "cond_disabled".to_string(),
                    enabled: false,
                    condition_type: "atomic".to_string(),
                    rule_set: vec![missing_json.to_string_lossy().into_owned()],
                    ..Default::default()
                },
            ],
            ..Default::default()
        };
        let ok_report = analyze_config_plan(&ok_store);
        assert!(ok_report.valid, "unexpected errors: {:?}", ok_report.errors);

        // 2. Missing local file (absolute and relative)
        let mut missing_store = RouterStoreData::default();
        missing_store.sections[0].rule_set_urls = vec![
            missing_json.to_string_lossy().into_owned(),
            "./missing_rel.trs".to_string(),
        ];
        let r_missing = analyze_config_plan(&missing_store);
        assert!(!r_missing.valid);
        assert!(r_missing.errors.len() >= 2);
        assert!(r_missing.errors.iter().any(|e| e.contains("missing.json")));
        assert!(r_missing.errors.iter().any(|e| e.contains("missing_rel.trs")));

        // 3. Malformed JSON, JSON without 'rules', JSON with non-array 'rules'
        for (bad_path, expected_substr) in [
            (&malformed_json, "invalid JSON"),
            (&no_rules_json, "'rules' array"),
            (&wrong_rules_type_json, "'rules' array"),
        ] {
            let mut st = RouterStoreData::default();
            st.conditions.push(TrafficCondition {
                id: "c_json_bad".to_string(),
                enabled: true,
                condition_type: "atomic".to_string(),
                rule_set: vec![bad_path.to_string_lossy().into_owned()],
                ..Default::default()
            });
            let rep = analyze_config_plan(&st);
            assert!(!rep.valid, "expected invalid for {:?}", bad_path);
            assert!(
                rep.errors.iter().any(|e| e.contains(expected_substr)),
                "errors {:?} did not mention {expected_substr}",
                rep.errors
            );
        }

        // 4. Empty / truncated / bad-magic .trs and .srs in child condition & rule_set_with_subnets
        for (bad_bin, expected_substr) in [
            (&empty_trs, "is empty"),
            (&short_trs, "truncated"),
            (&bad_magic_trs, "invalid TRS magic"),
            (&empty_srs, "is empty"),
            (&short_srs, "truncated"),
            (&bad_magic_srs, "invalid SRS magic"),
        ] {
            let mut st = RouterStoreData::default();
            st.conditions.push(TrafficCondition {
                id: "c_bin_child".to_string(),
                enabled: true,
                condition_type: "atomic".to_string(),
                rule_set_with_subnets: vec![bad_bin.to_string_lossy().into_owned()],
                ..Default::default()
            });
            st.conditions.push(TrafficCondition {
                id: "c_bin_parent".to_string(),
                enabled: true,
                condition_type: "all".to_string(),
                children: vec!["c_bin_child".to_string()],
                ..Default::default()
            });
            let rep = analyze_config_plan(&st);
            assert!(!rep.valid, "expected invalid for {:?}", bad_bin);
            assert!(
                rep.errors.iter().any(|e| e.contains(expected_substr)),
                "errors {:?} did not mention {expected_substr}",
                rep.errors
            );
        }

        let _ = std::fs::remove_dir_all(&tmp_dir);
    }

    #[tokio::test]
    async fn test_commit_transaction_aborts_on_bad_local_ruleset_keeping_previous_config() {
        let tmp_dir = std::env::temp_dir().join(format!(
            "tachyon_tx_abort_rs_{}_{}",
            std::process::id(),
            crate::crypto_gen::generate_hex(4)
        ));
        let _ = std::fs::remove_dir_all(&tmp_dir);
        std::fs::create_dir_all(&tmp_dir).expect("mkdir");
        let store_path = tmp_dir.join("store.json");
        let core_path = tmp_dir.join("tachyon-core-config.json");
        let bad_trs = tmp_dir.join("corrupt.trs");
        std::fs::write(&bad_trs, b"not-valid-trs-data-here").unwrap();

        let state = AppState::load_or_create(&store_path).expect("load_or_create");
        let mut initial = RouterStoreData::default();
        initial.settings.core_config_path = core_path.to_string_lossy().into_owned();
        initial.settings.tun_inet4 = "172.19.0.1/30".to_string();
        initial.settings.fakeip_inet4_range = "198.18.0.0/15".to_string();
        initial.settings.tun_inet6 = "fdfe:dcba:9876::1/126".to_string();
        initial.settings.fakeip_inet6_range = "fc00::/18".to_string();
        initial.sections[0].label = "Known Good Label".to_string();
        commit_transaction(&state, initial.clone())
            .await
            .expect("initial commit succeeds");

        let before_store_bytes = std::fs::read(&store_path).expect("read initial store.json");
        let before_core_bytes = std::fs::read(&core_path).expect("read initial core config");

        let mut bad_candidate = initial.clone();
        bad_candidate.sections[0].label = "Broken Label Must Not Persist".to_string();
        bad_candidate.sections[0]
            .rule_set_with_subnets
            .push(bad_trs.to_string_lossy().into_owned());

        let err = commit_transaction(&state, bad_candidate)
            .await
            .expect_err("commit_transaction must abort in VALIDATE on bad .trs");
        assert!(
            err.to_string().contains("Transaction validation failed"),
            "unexpected error: {err}"
        );

        let guard = state.data.read().await;
        assert_eq!(guard.sections[0].label, "Known Good Label");
        assert!(guard.sections[0].rule_set_with_subnets.is_empty());
        drop(guard);

        assert_eq!(
            std::fs::read(&store_path).expect("read store.json after abort"),
            before_store_bytes
        );
        assert_eq!(
            std::fs::read(&core_path).expect("read core config after abort"),
            before_core_bytes
        );

        let _ = std::fs::remove_dir_all(&tmp_dir);
    }
}
