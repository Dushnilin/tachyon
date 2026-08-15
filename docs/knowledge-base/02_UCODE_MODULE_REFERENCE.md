# 02. ucode Backend Module Reference

Tachyon's backend is modularized under `tachyon/files/usr/lib/tachyon/`. Modules are loaded dynamically via ucode's `require()` or executed directly via `ucode -L <lib_dir> <module> <command>`.

---

## 1. Core Subsystem (`core/`)

| Module | Key Functions & Responsibilities |
|---|---|
| `constants.uc` | Central repository of paths, default ports, mark values, version detection (`detect_installed_version()`), commit SHA resolver (`detect_installed_commit_sha()`), UCI config names. |
| `common.uc` | String manipulation (`trim`, `split_lines`), file helpers (`read_file`, `write_atomic`), logging formatters (`log_info`, `log_error`, `log_debug`). |
| `helpers.uc` | Process management (`popen_read`, `system_exec`), CIDR formatting, MAC address validators, integer conversions with safety fallbacks. |
| `ip.uc` | IP v4/v6 parser, subnet containment (`ip_in_subnet`), CIDR validator, loopback & private IP range detection. |
| `url.uc` | RFC 3986 URL parser, extraction of scheme, host, port, path, query params, hash fragment, safe URL encoding/decoding. |
| `uci.uc` | High-level wrapper over OpenWrt `libuci`: `get_section`, `set_option`, `add_section`, `delete_section`, atomic commit with lock. |
| `packages.uc` | Package manager abstraction: detects `opkg` vs `apk` (OpenWrt 25.x+), checks installed packages, versions, and dependencies. |
| `events.uc` | Internal event bus mechanism: publish/subscribe for service state transitions and notification dispatching. |

---

## 2. Service Management Subsystem (`service/`)

| Module | Key Functions & Responsibilities |
|---|---|
| `lifecycle.uc` | Service start, stop, restart, enable, disable. Coordinates teardown order (nftables -> singbox -> zapret -> dnsmasq) to prevent routing deadlocks. |
| `state.uc` | Comprehensive runtime state reader (`get_runtime_state()`): active proxy server, watchdog status, interface health, uptime, memory consumption. |
| `reload.uc` | Hot-reload planner (`plan_reload()`): inspects what changed in UCI and applies the minimal necessary restart (e.g. soft-reload sing-box vs full nftables rebuild). |
| `reset.uc` | Factory reset routines: wipes `/etc/config/tachyon`, cleans up temporary caches, restores default templates. |
| `watchdog.uc` | Autonomous supervisor loop: checks sing-box process, memory thresholds (OOM guard), DNS resolution, loop-restart mitigation (`safe_proxy_restart`). |
| `snapshot.uc` | Assembles a structured system snapshot JSON for AI Doctor and external diagnostics. |
| `agent_api.uc` | CGI handler for `/cgi-bin/tachyon-agent/`: handles routing, Bearer authentication validation, endpoint dispatch, JSON serialization. |
| `agent_mcp.uc` | Model Context Protocol (MCP) tool schema and handlers for integration with MCP clients (Cursor, Claude Desktop). |
| `telegram.uc` | Telegram Bot daemon: polling loop (`getUpdates`), command dispatcher (`/doctor`, `/ai_doctor`, `/fix`, `/restart`, `/status`), inline keyboards. |
| `warp_generator.uc` | Cloudflare WARP account generator & key exchange for auto-provisioning WireGuard outbounds. |
| `event_controller.uc` | Coordinates async background job workers, PID tracking, lock files, and log ring-buffer management. |

---

## 3. Diagnostics & AI Subsystem (`diagnostics/`)

| Module | Key Functions & Responsibilities |
|---|---|
| `runtime.uc` | **Local Rule Doctor & AI Doctor engine**: runs 10+ local heuristic checks, detects NTP desync, conntrack overflow, MTU issues, bootstrap DNS deadlock; applies 13+ quick fix codes (`apply_quick_fix()`), executes emergency internet restoration (`restore_native_internet()`). |
| `service_check.uc` | Health probes: tests sing-box TCP/UDP proxying, DNS response latency, WAN internet connectivity, gateway reachability. |
| `status.uc` | Detailed diagnostics status assembler for LuCI Diagnostic tab and CLI `tachyon doctor`. |

---

## 4. sing-box Subsystem (`singbox/`)

| Module | Key Functions & Responsibilities |
|---|---|
| `generator.uc` | Master sing-box JSON configuration compiler (`/tmp/tachyon/sing-box.json`): binds inbounds, outbounds, routing rules, DNS, experimental. |
| `generator_outbounds.uc` | Compiles VLESS (Reality/gRPC/WS), VMess, Shadowsocks, Trojan, Hysteria2, WireGuard, Direct, and Block outbounds. |
| `generator_routes.uc` | Compiles routing rules: domain matchers, IP CIDR matchers, GeoIP rules, client MAC/IP matchers, detour assignments. |
| `dns.uc` | Compiles sing-box DNS configuration: local DNS, remote DoH/DoT/UDP DNS, fakeip/direct resolution rules. |
| `dns_failover.uc` | High-availability DNS failover logic: switches between primary and secondary bootstrap DNS upon timeouts. |
| `dns_prefetch.uc` | Domain pre-fetching & cache warming for frequently accessed sites. |
| `dns_presets.uc` | Built-in DNS presets (Cloudflare, Google, AdGuard, Quad9, OpenDNS, Custom DoH). |
| `priority.uc` | Outbound group priority manager: auto-failover, fallback groups, URL-test latency sorting. |
| `route.uc` | Low-level sing-box route rule builder & selector logic. |
| `rulesets.uc` | Rule-set binary (`.srs`) and JSON ruleset compiler and parser. |
| `servers.uc` | Server node parser, validator, and URI serializer (VLESS, VMess, SS, Trojan, H2). |
| `subscription.uc` | Subscriptions processor: download, base64 decoding, node deduplication, format normalizer. |
| `urltest.uc` | RTT ping & latency testing worker: measures real response times across proxy servers. |

---

## 5. Providers & DPI Bypass Subsystem (`providers/`)

| Module | Key Functions & Responsibilities |
|---|---|
| `zapret/runtime.uc` | Manages **Zapret v1 (`nfqws`)** process arguments, queue numbers, NFQueue bindings, daemon start/stop. |
| `zapret2/runtime.uc` | Manages **Zapret v2 (`nfqws2`)** advanced multi-vector desync arguments (`--dpi-desync=multisplit`, `--dpi-desync-seqovl`). |
| `byedpi/runtime.uc` | Manages **ByeDPI (`ciadpi`)** SOCKS5 proxy daemon, port allocation, payload split parameters. |
| `nfqueue/runtime.uc` | Kernel NFQueue allocation table, prevents queue ID collisions between Zapret v1 and v2. |
| `rules.uc` | Maps UCI routing rules to specific provider action handlers (`action = zapret | zapret2 | byedpi | proxy`). |
| `status.uc` | Real-time process inspection and health monitoring of all active DPI bypass daemons. |

---

## 6. Networking & Firewall Subsystem (`nft/`, `dns/`)

| Module | Key Functions & Responsibilities |
|---|---|
| `nft/apply.uc` | Generates and commits nftables ruleset (`inet TachyonTable`): prerouting, output, divert chains, marks, fwmark, bypass sets. |
| `dns/apply.uc` | Coordinates DNS interception: configures dnsmasq forwarders, port redirection (`127.0.0.1:5353`), ipset / nftset auto-population. |

---

## 7. Configuration & Components Subsystem (`config/`, `components/`, `subscription/`)

| Module | Key Functions & Responsibilities |
|---|---|
| `config/validator.uc` | Strict UCI schema validation: validates IP addresses, ports, UUIDs, private keys, domain names, action modes. |
| `config/migration.uc` | Automatic migration engine: migrates configurations from legacy Forkop, Podkop Plus, and Podkop configs without data loss. |
| `components/updater.uc` | Background component installer/updater: handles downloading, unpacking, installing, and version checking of binaries. |
| `components/hosts.uc` | Remote hosts lists ingestor: fetches blocklists, merges into unified `combined.txt`, handles GitHub mirror failovers. |
| `subscription/cache.uc` | Atomic subscription cache store, prevents redundant network downloads. |
| `subscription/parser.uc` | Universal proxy URI parser: parses `vless://`, `vmess://`, `ss://`, `trojan://`, `hysteria2://`, `wireguard://`. |
