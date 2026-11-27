//! `tachyon` — Pure-Rust OpenWrt Routing Orchestrator, Control Plane & Embedded Web Panel.
//!
//! Single static binary, zero C/C++ dependencies, zero UCI/LuCI/ucode dependencies,
//! managing `tachyon-core` with native packet desynchronization and multi-protocol routing.

#![recursion_limit = "256"]

mod adguard_hosts;
mod ai_doctor;
mod api;
mod config_gen;
mod config_history;
mod core_mgr;
mod crypto_gen;
mod diagnostics;
mod fuzzer;
mod mcp;
mod net_stack;
mod net_stack_iptables;
mod platform;
mod platform_keenetic;
mod simple_regex;
mod smart_detect;
mod snapshots;
mod store;
mod switch_history;
mod sys_info;
mod tg_bot;
mod transaction;
mod ubus_bridge;
mod updater;
mod watchdog;

use std::io::{Read, Write};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpStream};
use std::sync::Arc;
use std::time::Duration;

use crate::core_mgr::CoreManager;
use crate::store::AppState;

fn resolve_effective_data_dir() -> std::path::PathBuf {
    if let Ok(explicit) = std::env::var("TACHYON_DATA_DIR") {
        let trimmed = explicit.trim();
        if !trimmed.is_empty() {
            return std::path::PathBuf::from(trimmed);
        }
    }
    let paths = platform::paths();
    #[cfg(target_os = "linux")]
    {
        if paths.data_dir.exists() || platform::is_entware() {
            return paths.data_dir.clone();
        }
        std::path::PathBuf::from("data")
    }
    #[cfg(not(target_os = "linux"))]
    {
        paths.data_dir.clone()
    }
}

fn resolve_cli_forward_port() -> u16 {
    let store_path = resolve_effective_data_dir().join("tachyon.json");
    if let Ok(raw) = std::fs::read_to_string(&store_path)
        && let Ok(val) = serde_json::from_str::<serde_json::Value>(&raw)
        && let Some(p) = val
            .pointer("/settings/listen_port")
            .and_then(|v| v.as_u64())
        && (1..=65535).contains(&p)
    {
        return p as u16;
    }
    1680
}

fn runtime_ipc_token_path() -> std::path::PathBuf {
    crate::store::runtime_state_dir().join("ipc.token")
}

fn runtime_daemon_pid_path() -> std::path::PathBuf {
    crate::store::runtime_state_dir().join("daemon.pid")
}

fn write_daemon_runtime_markers(local_ipc_token: &str) {
    let dir = crate::store::runtime_state_dir();
    let _ = std::fs::create_dir_all(&dir);
    let pid_path = runtime_daemon_pid_path();
    let _ = std::fs::write(&pid_path, format!("{}\n", std::process::id()));
    let tok_path = runtime_ipc_token_path();
    if std::fs::write(&tok_path, local_ipc_token).is_ok() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&tok_path, std::fs::Permissions::from_mode(0o600));
        }
    }
}

fn cleanup_daemon_runtime_markers() {
    let _ = std::fs::remove_file(runtime_ipc_token_path());
    let _ = std::fs::remove_file(runtime_daemon_pid_path());
}

fn daemon_pid_looks_alive() -> bool {
    let Ok(raw) = std::fs::read_to_string(runtime_daemon_pid_path()) else {
        return false;
    };
    let Ok(pid) = raw.trim().parse::<u32>() else {
        return false;
    };
    if pid == 0 {
        return false;
    }
    #[cfg(target_os = "linux")]
    {
        std::path::Path::new(&format!("/proc/{pid}")).exists()
    }
    #[cfg(not(target_os = "linux"))]
    {
        true
    }
}

fn try_forward_cli_to_daemon(args: &[String]) -> Option<(i32, String, String)> {
    let port = resolve_cli_forward_port();
    let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port);
    let mut stream = None;
    for attempt in 0..4u8 {
        match TcpStream::connect_timeout(&addr, Duration::from_millis(250)) {
            Ok(s) => {
                stream = Some(s);
                break;
            }
            Err(e)
                if attempt < 3
                    && e.kind() == std::io::ErrorKind::ConnectionRefused
                    && daemon_pid_looks_alive() =>
            {
                std::thread::sleep(Duration::from_millis(250));
            }
            Err(_) => return None,
        }
    }
    let mut stream = stream?;
    let _ = stream.set_read_timeout(Some(Duration::from_secs(25)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));

    let tachyon_bin = platform::paths()
        .bin_dir
        .join("tachyon")
        .to_string_lossy()
        .replace('\\', "/");
    let rpc_body = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "call",
        "params": [
            "00000000000000000000000000000000",
            "file",
            "exec",
            {
                "command": tachyon_bin,
                "params": args
            }
        ]
    });
    let body_bytes = serde_json::to_vec(&rpc_body).ok()?;
    let ipc_hdr = std::fs::read_to_string(runtime_ipc_token_path())
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .map(|tok| format!("X-Tachyon-Local-Token: {tok}\r\n"))
        .unwrap_or_default();
    let req = format!(
        "POST /ubus HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nContent-Type: application/json\r\n{ipc_hdr}Connection: close\r\nContent-Length: {}\r\n\r\n",
        body_bytes.len()
    );
    stream.write_all(req.as_bytes()).ok()?;
    stream.write_all(&body_bytes).ok()?;
    stream.flush().ok()?;

    let mut raw = Vec::new();
    stream.read_to_end(&mut raw).ok()?;
    let sep = raw.windows(4).position(|w| w == b"\r\n\r\n")?;
    let resp_body = &raw[sep + 4..];
    let val: serde_json::Value = serde_json::from_slice(resp_body).ok()?;
    let payload = val.get("result")?.as_array()?.get(1)?;
    let code = payload
        .get("code")
        .and_then(serde_json::Value::as_i64)
        .unwrap_or(0) as i32;
    let stdout = payload
        .get("stdout")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("")
        .to_string();
    let stderr = payload
        .get("stderr")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("")
        .to_string();
    Some((code, stdout, stderr))
}

const DAEMON_SHUTDOWN_BUDGET: Duration = Duration::from_millis(2200);

fn is_local_cli_subcommand(subcommand: &str) -> bool {
    matches!(
        subcommand,
        "daemon"
            | "serve"
            | "--daemon"
            | "mcp"
            | "status"
            | "quick_fix"
            | "rollback"
            | "import-legacy"
            | "import_legacy"
            | "explain"
            | "route_explain"
            | "config_plan"
            | "compile_config"
            | "compile_nft"
            | "compile_iptables"
            | "reconcile-net"
            | "reconcile_net"
            | "support_bundle"
            | "dns-selftest"
            | "dns_selftest"
            | "dns"
            | "diag"
            | "nodes-status"
            | "nodes_status"
            | "outbound-status"
            | "stop-shutdown"
            | "stop-and-restore-native"
            | "stop_and_restore_native"
    )
}

async fn run_graceful_shutdown_with_budget(
    state_sig: &AppState,
    core_sig: &CoreManager,
    budget: Duration,
) {
    cleanup_daemon_runtime_markers();
    let cleanup = async {
        if state_sig.is_disk_modified_externally() {
            eprintln!("[tachyon] preserving externally modified store on shutdown");
        } else if state_sig.is_dirty() {
            let _ = state_sig.save().await;
        }
        if core_sig.has_spawned_child().await {
            let _ = core_sig.stop_for_shutdown().await;
        }
    };
    if tokio::time::timeout(budget, cleanup).await.is_err() {
        eprintln!(
            "[tachyon] shutdown exceeded {}ms budget; forcing core stop",
            budget.as_millis()
        );
        core_sig.force_kill_spawned_child_fast().await;
    }
}

fn main() -> anyhow::Result<()> {
    sys_info::init_daemon_start_time();
    let args: Vec<String> = std::env::args().skip(1).collect();
    let subcommand_early = args.first().map(String::as_str).unwrap_or("daemon");
    if matches!(subcommand_early, "version" | "-v" | "--version") {
        println!("tachyon {}", crate::store::TACHYON_VERSION);
        return Ok(());
    }
    if matches!(subcommand_early, "-h" | "--help" | "help") {
        print!("{}", ubus_bridge::cli_help_text());
        return Ok(());
    }
    if !is_local_cli_subcommand(subcommand_early)
        && let Some((code, stdout, stderr)) = try_forward_cli_to_daemon(&args)
    {
        if !stdout.is_empty() {
            print!("{stdout}");
        }
        if !stderr.is_empty() {
            eprint!("{stderr}");
        }
        if code != 0 {
            std::process::exit(code);
        }
        return Ok(());
    }

    let data_dir = resolve_effective_data_dir();
    let store_path = data_dir.join("tachyon.json");

    let state = AppState::load_or_create(&store_path)?;
    let core = CoreManager::new(Arc::clone(&state));

    let rt = tokio::runtime::Builder::new_current_thread()
        .max_blocking_threads(4)
        .thread_stack_size(512 * 1024)
        .enable_all()
        .build()?;

    rt.block_on(async move {
        let subcommand = args.first().map(String::as_str).unwrap_or("daemon");
        match subcommand {
            "version" | "-v" | "--version" => {
                println!("tachyon {}", crate::store::TACHYON_VERSION);
                Ok(())
            }
            "status" => {
                core.poll_telemetry_and_reconcile(0).await;
                let doc = diagnostics::run_local_doctor(&state).await;
                println!("{}", serde_json::to_string_pretty(&doc)?);
                Ok(())
            }
            "quick_fix" => {
                let fix_id = args.get(1).map(String::as_str).unwrap_or("restart_core");
                let msg = diagnostics::apply_quick_fix(&state, &core, fix_id).await?;
                println!("{msg}");
                Ok(())
            }
            "rollback" => {
                let msg =
                    diagnostics::apply_quick_fix(&state, &core, "rollback_known_good").await?;
                println!("{msg}");
                Ok(())
            }
            "import-legacy" | "import_legacy" => {
                let mut candidate = state.data.read().await.clone();
                let count = match (args.get(1), args.get(2)) {
                    (Some(uci), Some(cache)) => candidate.import_legacy_router_files_with_cache(
                        &[std::path::Path::new(uci)],
                        std::path::Path::new(cache),
                    ),
                    (Some(uci), None) => candidate.import_legacy_router_files_with_cache(
                        &[std::path::Path::new(uci)],
                        std::path::Path::new("/etc/tachyon/subscription-cache"),
                    ),
                    _ => candidate.import_legacy_router_files(),
                };
                transaction::commit_transaction(&state, candidate).await?;
                println!("Imported {count} legacy router configuration objects.");
                Ok(())
            }
            "explain" => {
                let target = args.get(1).map(String::as_str).unwrap_or("www.youtube.com");
                let client_ip = args.get(2).map(String::as_str).unwrap_or("192.168.1.100");
                let d = state.data.read().await.clone();
                let res = diagnostics::explain_route_with_engine(
                    &core, &d, client_ip, target, 443, "tcp",
                )
                .await;
                println!("{}", serde_json::to_string_pretty(&res)?);
                Ok(())
            }
            "route_explain" => {
                let client_ip = args.get(1).map(String::as_str).unwrap_or("192.168.1.100");
                let target = args.get(2).map(String::as_str).unwrap_or("www.youtube.com");
                let port = args
                    .get(3)
                    .and_then(|p| p.parse::<u16>().ok())
                    .unwrap_or(443);
                let proto = args.get(4).map(String::as_str).unwrap_or("tcp");
                let nft_active = net_stack::check_nft_table_active().await;
                let d = state.data.read().await.clone();
                let res = diagnostics::build_route_trace_json(
                    &d,
                    client_ip,
                    target,
                    target,
                    port,
                    proto,
                    nft_active,
                );
                println!("{}", serde_json::to_string_pretty(&res)?);
                Ok(())
            }
            "config_plan" => {
                let d = state.data.read().await;
                let plan = transaction::analyze_config_plan(&d);
                println!("{}", serde_json::to_string_pretty(&plan)?);
                Ok(())
            }
            "compile_config" => {
                let d = state.data.read().await;
                let cfg = config_gen::compile_core_config(&d)?;
                println!("{}", serde_json::to_string_pretty(&cfg)?);
                Ok(())
            }
            "compile_nft" => {
                let d = state.data.read().await;
                print!("{}", net_stack::compile_nftables_ruleset(&d));
                Ok(())
            }
            "compile_iptables" => {
                let d = state.data.read().await;
                print!("{}", net_stack_iptables::compile_iptables_preview(&d));
                Ok(())
            }
            "reconcile-net" | "reconcile_net" => {
                let d = state.data.read().await.clone();
                net_stack::reconcile_network_stack(&d).await?;
                Ok(())
            }
            "support_bundle" => {
                let bundle = diagnostics::build_support_bundle(&state).await;
                println!("{}", serde_json::to_string_pretty(&bundle)?);
                Ok(())
            }
            "dns-selftest" | "dns_selftest" => {
                let mut seconds = 10u64;
                let mut domain = "example.com".to_string();
                let mut i = 2usize;
                while i < args.len() {
                    if args[i] == "--seconds" && let Some(v) = args.get(i + 1) {
                        seconds = v.parse::<u64>().unwrap_or(10);
                        i += 2;
                        continue;
                    }
                    if args[i] == "--domain" && let Some(v) = args.get(i + 1) {
                        domain = v.clone();
                        i += 2;
                        continue;
                    }
                    i += 1;
                }
                let res = diagnostics::run_dns_selftest(&state, seconds, &domain).await;
                println!("{}", serde_json::to_string_pretty(&res)?);
                Ok(())
            }
            "dns" if args.get(2).map(String::as_str) == Some("selftest") => {
                let mut seconds = 10u64;
                let mut domain = "example.com".to_string();
                let mut i = 3usize;
                while i < args.len() {
                    if args[i] == "--seconds" && let Some(v) = args.get(i + 1) {
                        seconds = v.parse::<u64>().unwrap_or(10);
                        i += 2;
                        continue;
                    }
                    if args[i] == "--domain" && let Some(v) = args.get(i + 1) {
                        domain = v.clone();
                        i += 2;
                        continue;
                    }
                    i += 1;
                }
                let res = diagnostics::run_dns_selftest(&state, seconds, &domain).await;
                println!("{}", serde_json::to_string_pretty(&res)?);
                Ok(())
            }
            "diag" => {
                let redacted = !args.iter().any(|a| a == "--raw");
                let rep = diagnostics::build_diag_report(&state, &core, redacted).await;
                println!("{}", serde_json::to_string_pretty(&rep)?);
                Ok(())
            }
            "nodes-status" | "nodes_status" | "outbound-status" => {
                let rep = diagnostics::build_nodes_status_report(&state, &core).await;
                println!("{}", serde_json::to_string_pretty(&rep)?);
                Ok(())
            }
            "mcp" => mcp::run_stdio_mcp(state, core).await,
            "start" => core.start().await,
            "stop" => core.stop().await,
            "stop-shutdown" => core.stop_for_shutdown().await,
            "stop-and-restore-native" | "stop_and_restore_native" => {
                core.stop().await?;
                net_stack::teardown_network_stack_with_mode(false).await;
                Ok(())
            }
            "doctor" => {
                let do_fix = args.iter().any(|a| a == "--fix");
                if do_fix {
                    let initial = diagnostics::run_local_doctor_with_core(&state, &core).await;
                    let safe_fixes: Vec<String> = initial
                        .findings
                        .iter()
                        .filter(|f| {
                            !f.quick_fix_id.is_empty()
                                && diagnostics::quick_fix_risk_tier(&f.quick_fix_id) == "safe"
                        })
                        .map(|f| f.quick_fix_id.clone())
                        .collect();
                    for fid in safe_fixes {
                        let _ = diagnostics::apply_quick_fix(&state, &core, &fid).await;
                    }
                }
                let final_rep = diagnostics::run_local_doctor_with_core(&state, &core).await;
                println!("{}", serde_json::to_string_pretty(&final_rep)?);
                Ok(())
            }
            "reload" | "restart" => {
                {
                    let d_snap = state.data.read().await;
                    ubus_bridge::sync_from_store_to_json_and_cache(&d_snap);
                }
                core.apply_or_reload().await
            }
            "daemon" | "serve" | "--daemon" => {
                ubus_bridge::mark_daemon_mode();
                core.enable_switch_history();
                write_daemon_runtime_markers(&state.local_ipc_token);
                eprintln!("[tachyon] store path: {}", store_path.display());

                let (listen_addr, port, base_path) = {
                    let d = state.data.read().await;
                    (
                        d.settings.listen_addr.clone(),
                        d.settings.listen_port,
                        d.settings.web_base_path.clone(),
                    )
                };
                let (listener, bound_addr) =
                    api::bind_panel_listener_with_retry(&listen_addr, port).await?;
                let server_handle = tokio::spawn(api::run_server_on_listener(
                    listener,
                    bound_addr,
                    base_path,
                    Arc::clone(&state),
                    Arc::clone(&core),
                ));

                let state_sig = Arc::clone(&state);
                let core_sig = Arc::clone(&core);
                tokio::spawn(async move {
                    #[cfg(unix)]
                    {
                        let mut sigterm = tokio::signal::unix::signal(
                            tokio::signal::unix::SignalKind::terminate(),
                        )
                        .expect("failed to install SIGTERM handler");
                        tokio::select! {
                            _ = tokio::signal::ctrl_c() => {}
                            _ = sigterm.recv() => {}
                        }
                    }
                    #[cfg(not(unix))]
                    {
                        let _ = tokio::signal::ctrl_c().await;
                    }
                    eprintln!("\n[tachyon] shutting down...");
                    run_graceful_shutdown_with_budget(
                        &state_sig,
                        &core_sig,
                        DAEMON_SHUTDOWN_BUDGET,
                    )
                    .await;
                    std::process::exit(0);
                });

                let mut attached = false;
                if let Some((ext_pid, _)) = sys_info::find_running_process_by_name("tachyon-core") {
                    let expected_bin = core.resolve_bin_path().await;
                    let running_exe = std::fs::read_link(format!("/proc/{ext_pid}/exe"))
                        .map(|p| p.to_string_lossy().to_string())
                        .unwrap_or_default();
                    let stale_exe = running_exe.ends_with(" (deleted)")
                        || (!running_exe.is_empty()
                            && !expected_bin.is_empty()
                            && running_exe != expected_bin);
                    if stale_exe {
                        eprintln!(
                            "[tachyon] restarting stale tachyon-core (PID {ext_pid}, exe={running_exe}, expected={expected_bin})"
                        );
                        match core.start().await {
                            Ok(()) => attached = true,
                            Err(e) => eprintln!("[tachyon] core restart failed: {e:#}"),
                        }
                    } else {
                        eprintln!("[tachyon] attached to running tachyon-core (PID {ext_pid})");
                        let identity = sys_info::capture_process_identity(ext_pid);
                        let store_snapshot = { state.data.read().await.clone() };
                        if let Err(e) = net_stack::apply_network_stack(&store_snapshot).await {
                            eprintln!("[tachyon] net_stack apply on attach failed: {e:#}");
                        }
                        let nft_ok = net_stack::check_nft_table_active().await;
                        let mut live = state.live.write().await;
                        live.core_running = true;
                        live.core_pid = Some(ext_pid);
                        live.core_identity = identity;
                        live.nft_table_active = nft_ok;
                        attached = true;
                    }
                }
                if !attached && !core.is_manually_stopped() {
                    for attempt in 0..3u8 {
                        if core.is_manually_stopped() {
                            break;
                        }
                        match core.start().await {
                            Ok(()) => break,
                            Err(e) => {
                                eprintln!(
                                    "[tachyon] initial core start attempt {}/3 failed: {e:#}",
                                    attempt + 1
                                );
                                if attempt < 2 {
                                    tokio::time::sleep(Duration::from_secs(if attempt == 0 {
                                        2
                                    } else {
                                        5
                                    }))
                                    .await;
                                }
                            }
                        }
                    }
                }
                core.refresh_core_version().await;
                core.poll_telemetry_and_reconcile(0).await;
                {
                    let d_snap = state.data.read().await;
                    ubus_bridge::sync_from_store_to_json_and_cache(&d_snap);
                }
                core.ensure_initial_binary_backups().await;
                core.spawn_background_loop();
                adguard_hosts::spawn_adguard_hosts_loop(Arc::clone(&state), Arc::clone(&core));
                smart_detect::spawn_smart_detect_loop(Arc::clone(&state), Arc::clone(&core));
                tg_bot::spawn_tg_bot_loop(Arc::clone(&state), Arc::clone(&core));

                server_handle
                    .await
                    .map_err(|e| anyhow::anyhow!("panel server task failed: {e}"))?
            }
            _ => {
                let (code, stdout, stderr) =
                    ubus_bridge::execute_tachyon_cli(&args, &state, &core).await;
                if !stdout.is_empty() {
                    print!("{stdout}");
                }
                if !stderr.is_empty() {
                    eprint!("{stderr}");
                }
                if code != 0 {
                    std::process::exit(code);
                }
                Ok(())
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    #[test]
    fn test_local_cli_subcommand_allowlist_includes_shutdown_commands() {
        assert!(is_local_cli_subcommand("stop-shutdown"));
        assert!(is_local_cli_subcommand("stop-and-restore-native"));
        assert!(is_local_cli_subcommand("stop_and_restore_native"));
        assert!(is_local_cli_subcommand("daemon"));
        assert!(is_local_cli_subcommand("status"));
        assert!(!is_local_cli_subcommand("reload"));
        assert!(!is_local_cli_subcommand("start"));
        assert!(!is_local_cli_subcommand("stop"));
    }

    #[tokio::test]
    async fn test_graceful_shutdown_completes_within_budget_even_if_core_stalls() {
        let dir = std::env::temp_dir().join(format!(
            "tachyon_main_shutdown_{}_{:08x}",
            std::process::id(),
            rand::random::<u32>()
        ));
        std::fs::create_dir_all(&dir).expect("create temp dir");
        let store_path = dir.join("store.json");
        let state = AppState::load_or_create(&store_path).expect("load state");
        {
            let mut d = state.data.write().await;
            d.settings.tun_mtu = 1412;
        }
        state
            .dirty
            .store(true, std::sync::atomic::Ordering::Release);
        let core = CoreManager::new(Arc::clone(&state));
        // Hold reload_lock to simulate an in-flight start/reload blocking stop_for_shutdown.
        let _lock_guard = core.reload_lock.lock().await;

        assert!(DAEMON_SHUTDOWN_BUDGET < Duration::from_millis(2500));
        let started = Instant::now();
        run_graceful_shutdown_with_budget(&state, &core, Duration::from_millis(250)).await;
        assert!(started.elapsed() < Duration::from_millis(1000));
        assert!(
            !state.is_dirty(),
            "dirty store must be saved before timeout"
        );

        let saved_raw = std::fs::read_to_string(&store_path).expect("saved store");
        assert!(saved_raw.contains("1412"));

        let _ = std::fs::remove_dir_all(&dir);
    }
}
