//! `tachyon` — Pure-Rust OpenWrt Routing Orchestrator, Control Plane & Embedded Web Panel.
//!
//! Single static binary, zero C/C++ dependencies, zero UCI/LuCI/ucode dependencies,
//! managing `tachyon-core` with native packet desynchronization and multi-protocol routing.

#![recursion_limit = "256"]

mod api;
mod config_gen;
mod core_mgr;
mod crypto_gen;
mod diagnostics;
mod fuzzer;
mod mcp;
mod net_stack;
mod snapshots;
mod store;
mod sys_info;
mod tg_bot;
mod transaction;
mod ubus_bridge;
mod updater;

use std::io::{Read, Write};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpStream};
use std::sync::Arc;
use std::time::Duration;

use crate::core_mgr::CoreManager;
use crate::store::AppState;

fn try_forward_cli_to_daemon(args: &[String]) -> Option<(i32, String, String)> {
    let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 1680);
    let mut stream = TcpStream::connect_timeout(&addr, Duration::from_millis(250)).ok()?;
    let _ = stream.set_read_timeout(Some(Duration::from_secs(25)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));

    let rpc_body = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "call",
        "params": [
            "00000000000000000000000000000000",
            "file",
            "exec",
            {
                "command": "/usr/bin/tachyon",
                "params": args
            }
        ]
    });
    let body_bytes = serde_json::to_vec(&rpc_body).ok()?;
    let req = format!(
        "POST /ubus HTTP/1.1\r\nHost: 127.0.0.1:1680\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: {}\r\n\r\n",
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

fn main() -> anyhow::Result<()> {
    sys_info::init_daemon_start_time();
    let args: Vec<String> = std::env::args().skip(1).collect();
    let subcommand_early = args.first().map(String::as_str).unwrap_or("daemon");
    if matches!(subcommand_early, "version" | "-v" | "--version") {
        println!("tachyon {}", crate::store::TACHYON_VERSION);
        return Ok(());
    }
    if !matches!(
        subcommand_early,
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
            | "support_bundle"
    ) && let Some((code, stdout, stderr)) = try_forward_cli_to_daemon(&args)
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

    let data_dir = std::env::var("TACHYON_DATA_DIR").unwrap_or_else(|_| {
        if cfg!(target_os = "linux") && std::path::Path::new("/etc/tachyon").exists() {
            "/etc/tachyon".to_string()
        } else {
            "data".to_string()
        }
    });
    let store_path = format!("{data_dir}/tachyon.json");

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
            "support_bundle" => {
                let bundle = diagnostics::build_support_bundle(&state).await;
                println!("{}", serde_json::to_string_pretty(&bundle)?);
                Ok(())
            }
            "mcp" => mcp::run_stdio_mcp(state, core).await,
            "start" => core.start().await,
            "stop" => core.stop().await,
            "reload" | "restart" => core.apply_or_reload().await,
            "daemon" | "serve" | "--daemon" => {
                ubus_bridge::mark_daemon_mode();
                eprintln!("[tachyon] store path: {store_path}");
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
                        if let Err(e) = core.start().await {
                            eprintln!("[tachyon] core restart failed: {e:#}");
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
                    }
                } else if !core.is_manually_stopped()
                    && let Err(e) = core.start().await
                {
                    eprintln!("[tachyon] initial core start skipped: {e:#}");
                }
                core.refresh_core_version().await;
                core.poll_telemetry_and_reconcile(0).await;
                {
                    let d_snap = state.data.read().await;
                    ubus_bridge::sync_section_cache(&d_snap);
                }
                core.ensure_initial_binary_backups().await;
                core.spawn_background_loop();
                tg_bot::spawn_tg_bot_loop(Arc::clone(&state), Arc::clone(&core));

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
                    if core_sig.has_spawned_child().await {
                        let _ = core_sig.stop().await;
                    }
                    let _ = state_sig.save().await;
                    std::process::exit(0);
                });

                api::run_server(state, core).await
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
