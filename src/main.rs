//! `tachyon` — Pure-Rust OpenWrt Routing Orchestrator, Control Plane & Embedded Web Panel.
//!
//! Single static binary, zero C/C++ dependencies, zero UCI/LuCI/ucode dependencies,
//! managing `tachyon-core` with native packet desynchronization and multi-protocol routing.

mod api;
mod config_gen;
mod core_mgr;
mod crypto_gen;
mod diagnostics;
mod mcp;
mod net_stack;
mod store;
mod sys_info;
mod tg_bot;
mod transaction;

use std::sync::Arc;

use crate::core_mgr::CoreManager;
use crate::store::AppState;

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();

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

    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;

    rt.block_on(async move {
        let subcommand = args.first().map(String::as_str).unwrap_or("daemon");
        match subcommand {
            "version" | "-v" | "--version" => {
                println!("tachyon {}", env!("CARGO_PKG_VERSION"));
                Ok(())
            }
            "status" | "doctor" => {
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
                let count = candidate.import_legacy_router_files();
                transaction::commit_transaction(&state, candidate).await?;
                println!("Imported {count} legacy router configuration objects.");
                Ok(())
            }
            "explain" => {
                let target = args.get(1).map(String::as_str).unwrap_or("www.youtube.com");
                let client_ip = args.get(2).map(String::as_str).unwrap_or("192.168.1.100");
                let d = state.data.read().await.clone();
                let res =
                    diagnostics::explain_route_with_engine(&core, &d, client_ip, target, 443, "tcp")
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
                let d = state.data.read().await;
                let res = diagnostics::explain_route(&d, client_ip, target, port, proto);
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
            _ => {
                eprintln!("[tachyon] store path: {store_path}");
                if let Some((ext_pid, _)) = sys_info::find_running_process_by_name("tachyon-core") {
                    eprintln!("[tachyon] attached to running tachyon-core (PID {ext_pid})");
                } else if let Err(e) = core.start().await {
                    eprintln!("[tachyon] initial core start skipped: {e:#}");
                }
                core.poll_telemetry_and_reconcile(0).await;
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
        }
    })
}
