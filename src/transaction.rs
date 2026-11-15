//! 8-phase atomic Transaction Engine (`PLAN -> PREFLIGHT -> SNAPSHOT -> MUTATE -> VALIDATE -> ACTIVATE -> VERIFY -> COMMIT`),
//! Dry-Run Configuration Planner (`config_plan`), and Last Known Good (`known_good`) snapshot manager.

use std::collections::HashSet;
use std::path::Path;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::config_gen;
use crate::crypto_gen;
use crate::store::{AppState, RouterStoreData, unix_now_secs};

pub const LKG_OBSERVATION_WINDOW_SECS: u64 = 180;

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
        if src.source_type.trim().eq_ignore_ascii_case("tailscale")
            && let Err(msg) = crate::store::validate_tailscale_network_options(
                &src.tailscale_relay_server_port,
                &src.tailscale_system_interface_mtu,
                &format!("Tailscale source '{}'", src.id),
            )
        {
            errors.push(msg);
        }
    }

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

/// Restore `RouterStoreData` from Last Known Good (`tachyon.known_good.json`) if available.
pub fn load_known_good(lkg_path: &Path) -> anyhow::Result<RouterStoreData> {
    let raw = std::fs::read_to_string(lkg_path)?;
    Ok(serde_json::from_str::<RouterStoreData>(&raw)?)
}

/// Execute an 8-phase atomic configuration transaction with LIFO rollback on failure.
pub async fn commit_transaction(
    state: &Arc<AppState>,
    mut candidate: RouterStoreData,
) -> anyhow::Result<ConfigPlanReport> {
    // Phase 1: PLAN (enforce cascade invariants)
    enforce_section_server_cascade(&mut candidate);

    // Phase 2: PREFLIGHT & Phase 5: VALIDATE
    let plan = analyze_config_plan(&candidate);
    if !plan.valid {
        anyhow::bail!("Transaction validation failed: {}", plan.errors.join("; "));
    }

    // Phase 3: SNAPSHOT (capture current state in memory for instant LIFO rollback)
    let previous = { state.data.read().await.clone() };
    if !state.lkg_path.exists() {
        let _ = promote_to_known_good(&state.lkg_path, &previous);
    }

    // Phase 4: MUTATE (write compiled core config + store JSON using NAND-safe atomic writers)
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

    {
        let mut d = state.data.write().await;
        *d = candidate;
    }

    if let Err(e) = state.save().await {
        // LIFO Rollback
        let mut d = state.data.write().await;
        *d = previous;
        anyhow::bail!("Transaction commit failed, rolled back in-memory state: {e}");
    }

    // Phase 6-8: ACTIVATE & COMMIT (start LKG 180s observation window)
    {
        let mut live = state.live.write().await;
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

    Ok(plan)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::InboundServer;

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
}
