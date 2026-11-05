# 02. ucode Backend Module Reference

Tachyon's backend is modularized under `tachyon/files/usr/lib/tachyon/`. Modules are loaded dynamically via ucode's `require()` or executed directly via `ucode -L <lib_dir> <module> <command>`.

---

## 1. Core Subsystem (`core/`)

| Module | Key Functions & Responsibilities |
|---|---|
| `constants.uc` | Central repository of paths, default ports (`1602`, `127.0.0.42:53`, `9090`, `4539`), fwmark values (`0x04000000`, `0x40000000`), version detection, UCI config names. |
| `common.uc` | String manipulation (`trim`, `as_string`, `substr`), flash-safe atomic file writers (`write_file`, `write_json_file`, `copy_file` with `content_unchanged()`), logging helpers. |
| `exec.uc` | Safe subprocess execution (`command_from_args`, `command_status_from_args`, `run_output`, background daemon builder) without shell injection. |
| `process.uc` | Core service contract (`tachyon-core` / `sing-box`) and PID-recycling-safe process identity (`pid` + `starttime` + `boot_id`). |
| `transaction.uc` | Atomic 8-phase transaction engine (`PLAN -> PREFLIGHT -> SNAPSHOT -> MUTATE -> VALIDATE -> ACTIVATE -> VERIFY -> COMMIT`) with LIFO rollback (`restore_file`, `remove_file`, `restore_uci`, `command`, `callback`). |
| `jobs.uc` | Asynchronous background job engine with PID+starttime+boot_id identity, heartbeat, cooperative cancellation, and critical sections. |
| `events.uc` | In-memory pub/sub bus and bounded ring journal (`/var/run/tachyon/events.jsonl`) with write-time secret redaction (`redact_string`, `redact_payload`). |
| `store.uc` | Two-layer state store separating persistent flash state (`/etc/tachyon/state/`) and volatile tmpfs state (`/var/run/tachyon/`). |
| `ip.uc` | IP v4/v6 parser, subnet containment (`ip_in_subnet`), CIDR validator, loopback & private IP range detection. |
| `url.uc` | RFC 3986 URL parser, extraction of scheme, host, port, path, query params, hash fragment, safe URL encoding/decoding. |
| `uci.uc` | High-level wrapper over OpenWrt `libuci`: `get_section`, `set_option`, `add_section`, `delete_section`, atomic commit with lock. |
| `packages.uc` | Package manager abstraction: detects `opkg` vs `apk` (OpenWrt 25.x+), checks installed packages, versions, and dependencies. |

---

## 2. Service Management Subsystem (`service/`)

| Module | Key Functions & Responsibilities |
|---|---|
| `lifecycle.uc` | Service start, stop, restart, reload, enable, disable. Coordinates teardown order and safe recovery. |
| `reconciler.uc` | Declarative desired-vs-actual state diffing (`engine`, `dns`, `nftables`, `routing`, `daemons`) and targeted drift repair without dropping active sessions. |
| `known_good.uc` | Last Known Good (`/etc/tachyon/state/known_good/`) snapshot capture, 180s observation window, promotion, and automatic rollback. |
| `config_plan.uc` | Dry-run configuration planner (`tachyon config_plan`): computes redacted UCI diffs, validates semantic references, detects port collisions and rule shadowing, and determines restart vs soft-reload impact. |
| `support_bundle.uc` | Redacted diagnostic archive builder (`tachyon support_bundle`) and central secret scrubber (`redact_string`, `redact_for_llm`, `is_sensitive_key`). |
| `state.uc` | Comprehensive runtime state reader (`get_runtime_state()`): active proxy server, watchdog status, interface health, uptime, memory consumption. |
| `reload.uc` | Hot-reload planner (`plan_reload()`): inspects what changed in UCI and applies the minimal necessary reload. |
| `reset.uc` | Factory reset routines: wipes `/etc/config/tachyon`, cleans up temporary caches, restores default templates. |
| `watchdog.uc` | Autonomous supervisor loop: checks core process, memory thresholds (OOM guard), WAN/Proxy/DNS fail streak hysteresis, Reconciler triggers, and Smart Detect. |
| `snapshot.uc` | Assembles a structured system snapshot JSON for AI Doctor and external diagnostics. |
| `agent_api.uc` | CGI handler for `/cgi-bin/tachyon-agent/`: handles routing, Bearer authentication validation, endpoint dispatch, privacy redaction, OpenAPI 3.0.3 & tool definitions. |
| `agent_mcp.uc` | Model Context Protocol (MCP) JSON-RPC 2.0 server (`tachyon-mcp` / `/mcp`): tools, embedded knowledge base resources, and privacy redaction. |
| `telegram.uc` | Telegram Bot daemon: polling loop (`getUpdates`), command dispatcher (`/doctor`, `/ai_doctor`, `/fix`, `/restart`, `/status`), inline keyboards. |
| `warp_generator.uc` | Cloudflare WARP account generator & key exchange for auto-provisioning WireGuard / AmneziaWG outbounds. |

---

## 3. Diagnostics & AI Subsystem (`diagnostics/`)

| Module | Key Functions & Responsibilities |
|---|---|
| `doctor.uc` | **Local Rule Doctor & AI Doctor v3.0 engine**: runs offline heuristic checks, live end-to-end verification, builds pre-redacted LLM prompts with architecture context and RAG documentation, and parses `FIX:` repair chains. |
| `repairs.uc` | Implements all 25 automated quick-fix actions (`apply_quick_fix()`), including `restore_native_internet`, `heal_network_stack`, `fix_bootstrap_dns`, `upgrade_to_singbox_extended`. |
| `rag.uc` | **Hybrid RAG Engine**: combines vector cosine similarity (`embed_query`) and domain-boosted lexical search (`lexical_search`, `search_docs`) over `/usr/lib/tachyon/rag_index.json` with strict query secret sanitization. |
| `route_explain.uc` | Packet path simulator (`tachyon route_explain`): traces client IP, target domain/IP, port, protocol through DNS/FakeIP, `inet TachyonTable`, `ip rule`, and matched `section`/`condition`/`outbound_source`/`balancer`. |
| `fuzzer.uc` & `fuzzer/ai.uc` | **Strategy Fuzzer & AI Strategy Generator**: benchmarks `zapret2`, `zapret`, `byedpi`, and native `desync` strategies in an isolated sandbox (NFQueue `298/299`, mark `0x08000000`) and synthesizes valid strategies via LLM+RAG. |
| `smart_detect.uc` | Autonomous degraded-domain detector (Default and Plus modes) with upstream DNS/WAN guard. |
| `runtime.uc` | Diagnostics CLI & RPC dispatcher delegating to `doctor.uc`, `repairs.uc`, `dns.uc`, `routing.uc`, and `status.uc`. |
| `service_check.uc` | Health probes: tests TCP/UDP proxying, DNS response latency, WAN internet connectivity, gateway reachability. |
| `status.uc` | Detailed diagnostics status assembler and UCI secret masker (`tachyon-config-masked`). |

---

## 4. Core Routing Generator Subsystem (`tachyon_core/`)

| Module | Key Functions & Responsibilities |
|---|---|
| `generator.uc` | Master JSON configuration compiler (`/etc/tachyon-core/config.json` or `/etc/sing-box/config.json`): binds inbounds (`:1602`), outbounds, routing rules, DNS (`127.0.0.42:53`), and Clash API (`127.0.0.1:9090`). |
| `generator_outbounds.uc` | Compiles VLESS (Reality/gRPC/WS/XHTTP), VMess, Shadowsocks, Trojan, Hysteria2, WireGuard, AmneziaWG (`add_awg_endpoint`), Direct, Block, and balancer outbounds. |
| `generator_routes.uc` | Compiles modular routing rules from `section` + `condition` + `outbound_source` + `balancer` + `outbound_group`. |
| `dns.uc` | Compiles core DNS configuration: local DNS, remote DoH/DoT/UDP DNS, FakeIP (`198.18.0.0/15`), and bootstrap DNS resolution rules. |
| `dns_failover.uc` | High-availability DNS failover logic: switches between primary and secondary resolvers upon timeouts. |
| `dns_prefetch.uc` | Domain pre-fetching & cache warming for frequently accessed domains. |
| `dns_presets.uc` | Built-in DNS presets (Cloudflare, Google, AdGuard, Quad9, OpenDNS, Custom DoH). |
| `priority.uc` | Outbound group priority manager: auto-failover, primary/backup cascade, URL-test latency sorting, and `fail_policy` handling. |
| `route.uc` | Low-level route rule builder & selector logic. |
| `rulesets.uc` | Rule-set binary (`.srs`) and JSON ruleset compiler and parser. |
| `servers.uc` | Server node parser, validator, and URI serializer. |
| `subscription.uc` | Subscriptions processor: download, base64 decoding, node deduplication, format normalizer. |
| `urltest.uc` | RTT ping & latency testing worker: measures real response times across proxy servers. |

---

## 5. Packet Desynchronization & Tunnel Providers Subsystem (`providers/`)

| Module | Key Functions & Responsibilities |
|---|---|
| `zapret/runtime.uc` | Manages **Zapret v1 (`nfqws`)** process arguments, queue numbers (`200+`), NFQueue bindings, daemon start/stop. |
| `zapret2/runtime.uc` | Manages **Zapret v2 (`nfqws2`)** Lua-based multi-profile desync arguments (`--lua-desync=multisplit:...`, queues `201+`). |
| `byedpi/runtime.uc` | Manages **ByeDPI (`ciadpi`)** SOCKS5 proxy daemon (`127.0.0.1:4539`), port allocation, payload split parameters. |
| `nfqueue/runtime.uc` | Kernel NFQueue allocation table, prevents queue ID collisions between Zapret v1 and v2. |
| `wdtt/runtime.uc` | Manages **WDTT** tunnel provider for WebRTC, Discord voice, and Telegram calls. |
| `olcrtc/runtime.uc` | Manages **OlcRTC** media and RTC relay provider. |
| `fptn/runtime.uc` | Manages **FPTN** tunnel client provider. |
| `tailscale/runtime.uc` | Manages **Tailscale** mesh VPN integration and routing rules. |
| `rules.uc` | Maps UCI routing sections to specific provider action handlers (`zapret`, `zapret2`, `byedpi`, `wdtt`, `olcrtc`, `fptn`, `proxy`). |
| `status.uc` | Real-time process inspection and health monitoring of all active provider daemons. |

---

## 6. Networking & Firewall Subsystem (`nft/`, `dns/`, `torrserver/`)

| Module | Key Functions & Responsibilities |
|---|---|
| `nft/apply.uc` | Generates and commits nftables ruleset (`inet TachyonTable`): prerouting, output, divert chains, fwmarks (`0x04000000`, `0x40000000`), and bypass sets (`localv4`, `localv6`, `tachyon_subnets`). |
| `dns/apply.uc` | Coordinates DNS interception: configures dnsmasq forwarders to `127.0.0.42:53`, FakeIP integration, and nftset auto-population. |
| `dns/speed_test.uc` | Measures latency and reliability across candidate DNS resolvers. |
| `torrserver/direct.uc` | Configures direct routing bypass for local TorrServer media streams. |

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
