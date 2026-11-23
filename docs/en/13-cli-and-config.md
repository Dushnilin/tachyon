# CLI and Configuration Reference

[Русский](../ru/13-cli-and-config.md) | [Back to Index](README.md)

## `/usr/bin/tachyon` Command-Line Interface

When `tachyon daemon` is running, CLI diagnostic subcommands forward requests through the local service bridge to query live memory counters and active session telemetry.

### Complete CLI Subcommand List (`src/main.rs`)

| Command | Arguments | Description |
|---|---|---|
| `tachyon version` (`-v`, `--version`) | — | Print the installed `tachyon` version |
| `tachyon status` | — | Run local `Doctor` diagnostics and output JSON health status |
| `tachyon explain` | `<target> [client_ip]` | Explain routing via live engine (`www.youtube.com`, `192.168.1.100` defaults) |
| `tachyon route_explain` | `[client_ip] [target] [port] [protocol]` | Simulate section/condition matching (`192.168.1.100 www.youtube.com 443 tcp` defaults) |
| `tachyon config_plan` | — | Validate current configuration, detect collisions, and print JSON plan |
| `tachyon compile_config` | — | Print compiled `tachyon-core` JSON configuration without reloading |
| `tachyon compile_nft` | — | Print compiled `nftables` ruleset to stdout |
| `tachyon quick_fix` | `[fix_id]` | Execute a verified quick-fix remediation by ID (default: `restart_core`) |
| `tachyon rollback` | — | Restore configuration to the Last Known Good (`rollback_known_good`) snapshot |
| `tachyon import-legacy` (`import_legacy`) | `[uci_path] [sub_cache_dir]` | Import legacy `/etc/config/tachyon` UCI store into `/etc/tachyon/tachyon.json` |
| `tachyon support_bundle` | — | Generate a redacted JSON diagnostic `support_bundle` |
| `tachyon mcp` | — | Start the JSON-RPC 2.0 MCP server over `stdio` for local AI clients |
| `tachyon start` / `stop` | — | Start or stop the `tachyon-core` child process |
| `tachyon reload` / `restart` | — | Recompile runtime config and reload or restart `tachyon-core` |
| `tachyon daemon` (`serve`, `--daemon`) | — | Run the primary orchestrator background service (default if no command given) |

Additional internal service and LuCI RPC actions (list updates, component updates, benchmarks) are handled via `/etc/init.d/tachyon` and `ubus_bridge`.

## Configuration Files Layout

### Persistent Storage (`/etc/tachyon/`, Flash)

- **`/etc/tachyon/tachyon.json`** — primary JSON database (`RouterStoreData`, `src/store.rs`). Top-level fields:

| Field | Purpose |
|---|---|
| `settings` | Global settings (`GlobalSettings`: proxy mode, DNS/FakeIP, IPv6/WebRTC, update channels, SQM/TCP, Tailscale, AI Doctor, Web UI, flash wear guard) |
| `sections` | Ordered list of routing sections (`RoutingSection`: priority, `action`, `condition_refs`, `outbound_source_refs`, `balancer_refs`, `fail_closed`, `kill_switch`) |
| `conditions` | Atomic and composite boolean traffic matchers (`TrafficCondition`) |
| `outbound_sources` | Layer-1 server and subscription pool (`OutboundSource`) |
| `balancers` | Decoupled URLTest, Priority, and Selector policies (`BalancerConfig`) |
| `outbound_groups` | Reusable node groups referenced by multi-tier balancers (`OutboundGroup`) |
| `servers` | Hosted router inbound server configurations (`InboundServer`) |
| `profiles` | Family profiles for grouped device filtering and quotas (`ParentalProfile`) |
| `schedules` | Time-based access schedules (`ScheduleRule`) |
| `guest_mode` | Guest network isolation and quota rules (`GuestModeConfig`) |
| `telegram` | Telegram bot credentials, event flags, quiet hours, and `managed_routers` (`TgBotConfig`) |
| `device_registry` | Cached LAN device metadata (`DeviceMeta`) |
| `applied_migrations` | Applied configuration schema migration markers |

- **`/etc/tachyon/config_sections.json`** — synchronized UCI-compatible section map served to LuCI views.
- **`/etc/tachyon-core/config.json`** — auto-generated `tachyon-core` runtime config (do not edit manually; regenerated on reload).
- **`/etc/tachyon/rulesets/`**, **`/etc/tachyon/subscription-cache/`**, **`/etc/tachyon/hosts-lists/`** — cached `.trs` rule sets, subscriptions, and host blocklists written only when content changes.

### Volatile Runtime State (`/var/run/tachyon/` and `/tmp/`, RAM / tmpfs)

All transient files live in memory (`tmpfs`) to eliminate NAND wear:

- `/var/run/tachyon/section-errors.json` — quarantined section validation diagnostics.
- `/var/run/tachyon/system-info.json` and `/var/run/tachyon/ui-state/` — cached system telemetry and proxy/connection state.
- `/var/run/tachyon/section-cache/` — parsed per-section outbound metadata, balancers, and subscription headers.
- `/var/run/tachyon/telegram.heartbeat` — Telegram bot polling liveness timestamp.
- `/tmp/tachyon-core/tachyon-core.log` — `tachyon-core` runtime log output.
- `/tmp/tachyon-install.log` — installer log from the latest install/upgrade run.

> [!TIP]
> For testing or custom deployments, override the data storage path with the `TACHYON_DATA_DIR` environment variable.

---

[Previous: Troubleshooting and FAQ](12-troubleshooting-faq.md) | [Back to Index](README.md) | [Next: Agent REST API and MCP Server](14-api-and-mcp.md)
