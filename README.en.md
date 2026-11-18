<p align="center">
  <img src="./assets/readme/hero.svg" width="100%" alt="Tachyon — network routing, proxy orchestration, and L3/L4 traffic shaping for OpenWrt">
</p>

<p align="center">
  <a href="https://github.com/Dushnilin/tachyon/releases"><img src="https://img.shields.io/github/v/release/Dushnilin/tachyon?color=38bdf8&labelColor=19191b" alt="Latest Release"></a>
  <a href="https://openwrt.org/"><img src="https://img.shields.io/badge/openwrt-23.05%20%7C%2024.10%20%7C%2025.x%20%7C%20snapshot-232325?labelColor=19191b" alt="OpenWrt Compatibility"></a>
  <a href="https://github.com/Dushnilin/tachyon-core"><img src="https://img.shields.io/badge/core-tachyon--core%20(Rust)-232325?labelColor=19191b" alt="Routing Core"></a>
  <a href="https://github.com/Dushnilin/tachyon-lists"><img src="https://img.shields.io/badge/lists-tachyon--lists%20(143)-232325?labelColor=19191b" alt="Tachyon Lists"></a>
  <a href="https://t.me/tachyon_proxy"><img src="https://img.shields.io/badge/telegram-%40tachyon__proxy-232325?labelColor=19191b" alt="Telegram Channel"></a>
  <a href="./LICENSE"><img src="https://img.shields.io/github/license/Dushnilin/tachyon?color=232325&labelColor=19191b" alt="License"></a>
</p>

<p align="center">
  <sub><a href="README.md">Русский</a> · <b>English</b> · <a href="https://github.com/Dushnilin/tachyon-core">tachyon-core</a> · <a href="https://github.com/Dushnilin/tachyon-lists">tachyon-lists</a> · <a href="https://boosty.to/tachyon">Boosty</a></sub>
</p>

---

**Tachyon** is a network routing, selective proxy orchestration, and L3/L4 traffic-shaping package for **OpenWrt** routers (`23.05`, `24.10`, `25.x`, and `SNAPSHOT`). It builds upon **[Forkop (@ushan0v)](https://github.com/ushan0v/forkop)** and the original **[Podkop (@itdoginfo)](https://github.com/itdoginfo/podkop)** architecture.

The package integrates the native Rust routing core **[tachyon-core](https://github.com/Dushnilin/tachyon-core)** (including built-in **Desync Adaptive 2.0**, **CSQTT/WDTT** transport, and native **Tailscale**), **AmneziaWG / WireGuard**, **OpenVPN (`.ovpn`)**, and **FPTN** L3 tunnels with a combinatorial strategy fuzzer, as well as **AI Doctor v3.0** self-diagnostics, a **Telegram management bot**, an **HTTP REST Agent API (OpenAPI 3.0)**, and an **MCP server**. All backend logic is implemented in **ucode** — OpenWrt's native C interpreter — running on routers with 128 MB RAM or more without external language runtimes.

---

<p align="center">
  <img src="./assets/readme/section-quickstart.svg" width="100%" alt="01 — Quick Start & Transactional Installation (install.sh)">
</p>

<p align="center">
  <img src="./assets/readme/install_terminal.svg" width="100%" alt="Tachyon transactional installer command">
</p>

Run the transactional installer in a single SSH command on the router:

```bash
wget -O /tmp/tachyon-setup.sh https://raw.githubusercontent.com/Dushnilin/tachyon/main/install.sh && sh /tmp/tachyon-setup.sh
```

To install non-interactively with the native Rust `tachyon-core` routing core:

```bash
sh /tmp/tachyon-setup.sh -y
```

| Option or Mechanism | Behavior |
|:---|:---|
| `--tachyon-core` / `--skip-engine` | Installs the native Rust `tachyon-core` engine (~4.2 MiB idle RAM) by default, or skips core installation when `--skip-engine` is passed |
| Interactive selection | When run without flags, checks for `tachyon-core`, offers to install it if absent, and prompts for the release version |
| Transactional snapshots | Saves a configuration backup in `/etc/tachyon/installer-backups/` and records `apk-world` state before changes; automatically rolls back on failure |
| Memory protection (`zram-swap`) | On devices with ≤ 256 MB RAM, inspects available memory and offers to enable `zram-swap` |
| Automatic migration | Safe validation, backup, and automatic schema updates for `/etc/config/tachyon` |
| `--repair` / `--reinstall` | Rebuilds network tables, firewall hooks, and reinstalls packages over the current setup |
| `--channel beta` / `--tag X.Y.Z` | Switches to pre-release builds or installs a specific tagged version |

<details>
<summary><b>Installation mirrors (when direct access to raw.githubusercontent.com is throttled or blocked)</b></summary>

<br>

```bash
# Mirror 1 (jsdelivr.net CDN):
wget -O /tmp/tachyon-setup.sh https://cdn.jsdelivr.net/gh/Dushnilin/tachyon@main/install.sh && sh /tmp/tachyon-setup.sh

# Mirror 2 (gh-proxy.com):
wget -O /tmp/tachyon-setup.sh https://gh-proxy.com/raw.githubusercontent.com/Dushnilin/tachyon/main/install.sh && sh /tmp/tachyon-setup.sh

# Mirror 3 (ghfast.top):
wget -O /tmp/tachyon-setup.sh https://ghfast.top/https://raw.githubusercontent.com/Dushnilin/tachyon/main/install.sh && sh /tmp/tachyon-setup.sh
```

</details>

---

<p align="center">
  <img src="./assets/readme/section-architecture.svg" width="100%" alt="02 — Architecture & Traffic Processing Pipeline">
</p>

<p align="center">
  <img src="./assets/readme/architecture.svg" width="100%" alt="Tachyon Traffic Classification and Routing Pipeline">
</p>

Tachyon classifies flows via kernel **nftables** (`fw4`) and dispatches traffic across five outbound contours without unnecessary userspace hops:

| Processing Contour | Kernel & Daemon Mechanism | Purpose |
|:---|:---|:---|
| **1. Direct WAN** | Direct routing bypassing TPROXY/TUN (`0 ms overhead`) | Domestic banking, government portals, local CDNs, and trusted subnets |
| **2. Native Desync** | Built-in `desync` module (Adaptive 2.0) inside `tachyon-core` | TCP/TLS/HTTP segmentation and per-connection shaping (`auto`, `multisplit`, `fake`, `disorder`) directly inside the routing core without external daemons or NFQUEUE |
| **3. Proxy Core** | `tachyon-core` (Rust) | Selective routing by domains, `.trs` (priority) and `.srs`/`.lst` rule-sets, subnets, and LAN clients over VLESS Reality/XHTTP, Hysteria2, Trojan, VMess, and Shadowsocks |
| **4. CSQTT & Tailscale** | In-core transports and mesh networking in `tachyon-core` | CSQTT/WDTT profiles with multi-tier pools/failover, plus native Tailscale endpoints (MagicDNS) without an external `tailscaled` daemon |
| **5. L3 Tunnels** | Kernel `tun` / WireGuard interfaces (table `4249` for FPTN) | Packet-level tunneling via AmneziaWG (`AWG 2.0/3.0/3.1`), WireGuard, built-in OpenVPN (`.ovpn`), and `fptn-client-cli` over WebSocket/TLS |
| **6. Smart DNS** | FakeIP (`198.18.0.0/15`) + UDP/TCP port 53 interception | Isolated name resolution over DoH, DoT, DoQ, and HTTP/3 with continuous upstream health checks (`dns_failover.uc`) and ISP anti-hijack protection |

---

<p align="center">
  <img src="./assets/readme/section-subsystems.svg" width="100%" alt="03 — Subsystems & Functional Modules">
</p>

### 1. Routing Core (`tachyon-core`)

All selective routing, proxy tunneling, and DNS isolation run on the single native **`tachyon-core`** engine, with automated `nftables`, interface, and DNS orchestration:

| Component | Runtime Stack | Key Technical Characteristics |
|:---|:---|:---|
| **`tachyon-core`** | Pure Rust (Zero-C-Crypto, no GC runtime) | Around **4.2 MiB RAM** idle footprint; zero-copy `mmap` for priority `.trs` rule-sets and support for binary `.srs` lists; built-in Outbound Desync (TCP/TLS/HTTP split) in the core network stack; asynchronous XHTTP transport (`packet-up`, `auto`); Brutal CC congestion control for Hysteria2; integrated FPTN L3 tunnel and OpenVPN client; automatic rollback to `fallback.json` on validation errors; builds for `aarch64`, `armv7`, `armv6`, `x86-64`, and `MIPS/MIPSEL soft-float` (MT7620/MT7621/MT7628) |

---

### 2. Protocols, Subscriptions, and Selective Routing

* **AmneziaWG `2.0 / 3.0 / 3.1` (`.conf`) Import**: a dedicated named list between Connection URL and text links in section settings. Original configurations are stored in the UCI option `selector_amnezia_configs` (up to 64 KiB including name, one `Interface` and one `Peer`; DNS and command hooks in the file are ignored).
* **Built-in OpenVPN Client (`.ovpn`)**: direct upload and validation of `.ovpn` profiles in LuCI for `tachyon-core`.
* **FPTN Tunnel (`fptn-client-cli`)**: L3 packet tunneling over WebSocket/TLS over standard HTTPS transport (`tun-fptn` interface, routing table `4249`).
* **Subscription Processing**:
  * **Happ (`crypt2`–`crypt5`)** encrypted subscription decryption.
  * **Dual HWID** client header emulation.
  * **TLS Certificate SHA-256 Pinning** (`pcs` parameter validation).
  * **Anti-Collapse Shrink Guard**: preserves the working node cache when upstream subscription servers return empty or temporary error responses.
* **Cloudflare WARP / AmneziaWG Profile Generator**: built-in `tachyon generate_warp` command.
* **Smart Detect Exclusions (`smart_detect_exclude_lists`)**: under Settings → Services and access, manual domain exclusions can be combined with service presets in Default and Plus modes. Decoded caches are stored in `/etc/tachyon/smart-detect-exclusions/` and refreshed during scheduled list updates using `tachyon-core`. When root domain expansion would overlap an excluded subdomain, only the specific detected hostname is retained.

---

### 3. Smart DNS Stack and Leak Protection

* **FakeIP Pool (`198.18.0.0/15`)**: immediate connection establishment without waiting for remote DNS round-trips.
* **Encrypted Transports**: DNS over HTTPS (DoH), DNS over TLS (DoT), DNS over QUIC (DoQ), and DNS over HTTP/3.
* **Autonomous DNS Failover (`dns_failover.uc`)**: continuous upstream health monitoring and zero-downtime switching to backup resolvers.
* **Kernel Anti-DNS Hijack**: transparent interception of UDP/TCP port 53 via `nftables`.
* **DNS Leak Checker ([`docs/DNS_LEAK_CHECK.md`](docs/DNS_LEAK_CHECK.md))**: verifies active resolvers while filtering internal service records; **Plus** mode additionally tests the router's local DNS, unencrypted WAN queries, and an independent DoH/TLS probe.
* **Hosts Engine (`dns_hosts`)**: static hostname overrides and remote blocklist ingestion (AdAway, StevenBlack, Antizapret) with automatic GitHub mirror fallback (`jsdelivr`, `gh-proxy`).
* **DNS Benchmark & Autotune**: resolver latency benchmarking (`tachyon dns_benchmark`) and automated fastest-upstream selection (`tachyon dns_autotune --apply`).

---

### 4. Packet Shaping Strategy Generator and Fuzzer (Packet Fuzzer v2)

* **Modular Architecture (`fuzzer/*`)**: dedicated modules for network profiling, probe execution, stability scoring, and strategy generation for the native `desync` engine.
* **Two-Stage Verification (Probe v2 & Stable Scoring)**: eliminates false positives on lossy or unstable links.
* **30 Curated Presets & Combinatorial `desync` Matrix**: built-in `Adaptive 2.0` (`preset=auto`), `fake_split`, `fake_disorder`, `multi_disorder`, `multi_split`, `tlsrec`, `oob`, plus tunable parameters (`split_pos`, `fooling`, `fake_ttl`, `fake_sni`, `repeats`).
* **Isolated Probe Bench**: benchmarks run in an isolated temporary `tachyon-core` instance across custom multi-domain targets without interrupting active LAN traffic.

---

### 5. AI Doctor v3.0 Self-Diagnostics, REST Agent API, and MCP Server

<p align="center">
  <img src="./assets/readme/ai_doctor_showcase.svg" width="100%" alt="AI Doctor v3.0, REST Agent API, and MCP Server">
</p>

* **Modular Diagnostics (`diagnostics/doctor.uc`, `repairs.uc`, `system_info.uc`, `routing.uc`, `dns.uc`)**:
  * Runs offline local checks (`tachyon doctor`) or LLM-assisted root-cause analysis (**OpenAI**, **Claude**, **DeepSeek**, **Gemini**, **OpenRouter**, **Ollama**) via `tachyon ai_doctor`.
  * **Symptom Collapsing**: deduplicates cascading network failures into primary root causes.
* **Conflict-Resilient Rollback**: automatically reverts to the last known valid configuration if syntax errors occur in `dnsmasq` or `nftables`.
* **Emergency WAN Recovery**: `tachyon restore_native_internet` immediately disables traffic interception and restores direct WAN connectivity.
* **Model Context Protocol (`tachyon mcp`)**: standard JSON-RPC 2.0 `stdio` server for connecting the router to Claude Desktop, Cursor, and Antigravity.
* **HTTP REST Agent API (`/cgi-bin/tachyon-api`)**: OpenAPI 3.0.3 schema, Bearer token authentication with granular read/write scopes, and asynchronous service reloads without dropping client HTTP connections.

<details>
<summary><b>All 22 quick-fix repair codes in <code>diagnostics/repairs.uc</code> (<code>tachyon apply_quick_fix &lt;code&gt;</code>)</b></summary>

<br>

| Category | Automated Repair Codes |
|:---|:---|
| **Services & Memory (4)** | `start_tachyon_core`, `restart_tachyon_core_dns`, `start_watchdog`, `optimize_memory` |
| **Network & DNS (13)** | `rebuild_rules`, `fix_dnsmasq`, `fix_resolv_symlink`, `clear_dns_cache`, `fix_wan_interface`, `fix_gateway`, `reset_firewall`, `restart_network`, `switch_to_doh`, `fix_bootstrap_dns`, `heal_network_stack`, `enable_safe_bypass`, `restore_native_internet` |
| **Config & Platform (5)** | `fix_uci_config`, `update_subscriptions`, `fix_system_time`, `flush_conntrack`, `optimize_mtu` |

</details>

---

### 6. Interactive Telegram Control Bot

<p align="center">
  <img src="./assets/readme/telegram_bot_showcase.svg" width="100%" alt="Telegram Control Bot">
</p>

* **Clash API Integration**: authenticated control via Secret Token, extended system telemetry (`/info`), and on-the-fly proxy node and section switching.
* **Active Connection Monitor**: paginated list of open connections (`/connections`) and instant session termination (`/close_connections`).
* **Dedicated Worker Process**: heartbeat grace periods, zombie process prevention, and instance deduplication.
* **LAN Access Control**: quiet hours (`/qh`) and per-device access toggling by MAC address.
* **Supported Commands**: `/doctor`, `/ai_doctor`, `/heal`, `/speed`, `/ping`, `/test`, `/logs`, `/info`, `/export_config`, `/restart`, `/lang`.

---

### 7. Watchdog, Process Identity, and Flash Wear Protection

<p align="center">
  <img src="./assets/readme/watchdog_showcase.svg" width="100%" alt="Watchdog, Process Identity, and Flash Wear Protection">
</p>

* **PID Provenance & Identity (`core/process.uc`)**: verifies `pid`, `starttime`, and `boot_id` before sending signals, preventing accidental termination of recycled system PIDs. The same module defines the `procd` service contract and generates `/etc/init.d/tachyon-core`, stopping the daemon by executable path rather than calling `killall` on its own command name.
* **Transactional Package Manager (`core/packages.uc`)**: cleans stale locks, verifies ELF headers on UPX-compressed binaries, and scrubs `/etc/apk/world` to prevent `PROVIDES/REPLACES` conflicts during upgrades.
* **NAND Flash Wear Guard (`core/common.uc`)**: all file helpers (`write_file`, `write_json_file`, `copy_file`) check `content_unchanged()` before writing so identical rule-sets or configs never trigger redundant flash writes; runtime state stays in `tmpfs` (`/tmp`, `/var/run`).
* **Restart-Loop & OOM Protection**: caps restarts at 3 per 10 minutes under the `PROXY_RESTART_LOCK` mutex, dynamically manages memory limits, and supports configuration snapshots (`snapshot_save` / `snapshot_restore`).

---

### 8. Parental Controls, Traffic Quotas, and Smart QoS

* **Per-Device Schedules**: time-of-day and day-of-week internet access rules for LAN devices.
* **Traffic Quotas (`parental_quota.uc`)**: ingress/egress volume caps per device with automated `cron` resets.
* **Smart QoS & Priority Daemon**: DSCP packet tagging in `nftables` to prioritize latency-sensitive voice, gaming, and RTC flows while mitigating Bufferbloat.

---

### 9. LuCI Web Interface (TypeScript)

<p align="center">
  <img src="./assets/readme/luci_web_showcase.svg" width="100%" alt="LuCI Web Interface in TypeScript">
</p>

* **Real-Time Memory Telemetry**: displays exact RAM consumption by Tachyon daemons and estimated `dnsmasq` cache size on the dashboard.
* **Step-by-Step Update Progress**: structured step indicator for list and subscription updates instead of raw log dumps.
* **1-Click Section Cloning (`Copy`)**: duplicates complex routing rules and section parameters.
* **Integrated Modals**: `tachyon-core` status and runtime controls, strategy fuzzer modal with HTTP status codes, and streaming terminal for component installation and version rollbacks.

---

<p align="center">
  <img src="./assets/readme/section-cli.svg" width="100%" alt="04 — CLI Reference, REST API, and Maintenance">
</p>

<p align="center">
  <img src="./assets/readme/cli_showcase.svg" width="100%" alt="CLI, HTTP REST Agent API, and Model Context Protocol">
</p>

```bash
# Routing Core Controls (tachyon-core)
tachyon engine_status                           # Active tachyon-core runtime status (JSON)
tachyon engine_info                             # Capabilities and metadata for tachyon-core
tachyon engine_reload                           # Regenerate config and reload tachyon-core
tachyon get_tachyon_core_status                 # Service status for tachyon-core

# Packet Strategy Fuzzer & Benchmarks
tachyon fuzzer_start youtube_suite desync       # Start YouTube connectivity benchmark on desync
tachyon fuzzer_start discord_suite desync       # Start Discord benchmark (voice + UDP RTC)
tachyon fuzzer_status                           # Current fuzzer progress & results (JSON)
tachyon fuzzer_stop                             # Terminate fuzzer & clean test harness
tachyon fuzzer_apply <strategy_id>              # Apply winning strategy to UCI configuration

# DNS Testing & Route Tracing
tachyon dns_benchmark                           # Benchmark latency & reachability of DNS resolvers
tachyon dns_autotune --apply                    # Auto-select and apply the fastest DNS resolver
tachyon test_rule google.com                    # Test which routing section matches a domain or IP

# Local & LLM Diagnostics
tachyon doctor                                  # Run local offline diagnostics without LLM
tachyon ai_doctor                               # Run AI Doctor analysis with LLM
tachyon ai_doctor_last                          # View last saved diagnostic report
tachyon apply_quick_fix clear_dns_cache         # Execute a quick-fix code from diagnostics/repairs.uc
tachyon diagnose_json                           # Output full diagnostic state snapshot (JSON)
tachyon restore_native_internet                 # Emergency stop proxy interception and restore pure WAN

# Telegram Bot & Watchdog Management
tachyon telegram_status                         # Check Telegram bot daemon state
tachyon telegram_diagnose                       # Run Telegram API connection diagnostics (JSON)
tachyon telegram_start                          # Start Telegram bot worker
tachyon telegram_stop                           # Stop Telegram bot worker
tachyon ai_heal                                 # Trigger manual Watchdog self-healing cycle
tachyon ai_status                               # Concise Watchdog status
tachyon ai_status_full                          # Extended Watchdog metrics (JSON)

# Configuration Snapshots, Lists & Generators
tachyon snapshot_list                           # List saved configuration snapshots
tachyon snapshot_save my_working_setup          # Save a named configuration snapshot
tachyon snapshot_restore /etc/config/snap.json  # Restore configuration from snapshot file
tachyon backup                                  # Create full configuration backup archive
tachyon list_update                             # Force update and compile domain/subnet lists
tachyon subscription_update                     # Refresh all proxy subscriptions
tachyon hosts_list_update                       # Update remote Hosts blocklists
tachyon generate_warp                           # Generate Cloudflare WARP / AmneziaWG configuration
tachyon generate_reality_keypair                # Generate X25519 keypair for VLESS Reality

# AI Integration (MCP & HTTP REST API)
tachyon mcp                                     # Start Model Context Protocol server (JSON-RPC 2.0 stdio)
curl http://192.168.1.1/cgi-bin/tachyon-api/health
curl http://192.168.1.1/cgi-bin/tachyon-api/openapi.json
```

### Clean Uninstallation (`uninstall.sh`)

The uninstaller stops active services, flushes `nftables` rules, restores default DNS settings, and saves a configuration backup to `/etc/config/tachyon.backup-<timestamp>`:

```bash
wget -O /tmp/tachyon-uninstall.sh https://raw.githubusercontent.com/Dushnilin/tachyon/main/uninstall.sh && sh /tmp/tachyon-uninstall.sh
```

| Flag | Action |
|:---|:---|
| `-y`, `--yes` | Non-interactive execution without confirmation prompts |
| `-p`, `--purge` | Remove all package files including configurations and backups |
| `--keep-binaries` | Preserve installed binaries (`tachyon-core` and auxiliary tools) on the system |

<details>
<summary><b>Uninstallation commands via mirrors</b></summary>

<br>

```bash
# Mirror 1 (jsdelivr.net CDN):
wget -O /tmp/tachyon-uninstall.sh https://cdn.jsdelivr.net/gh/Dushnilin/tachyon@main/uninstall.sh && sh /tmp/tachyon-uninstall.sh

# Mirror 2 (gh-proxy.com):
wget -O /tmp/tachyon-uninstall.sh https://gh-proxy.com/raw.githubusercontent.com/Dushnilin/tachyon/main/uninstall.sh && sh /tmp/tachyon-uninstall.sh
```

</details>

---

## Upstream Projects and Credits

* **[Forkop (@ushan0v)](https://github.com/ushan0v/forkop)** — direct parent repository (formerly Podkop Plus).
* **[Podkop (@itdoginfo)](https://github.com/itdoginfo/podkop)** — original project that established the core routing design.
* **[tachyon-core](https://github.com/Dushnilin/tachyon-core)** — pure-Rust proxy engine (~4.2 MiB idle RAM, zero external runtime or C dependencies).
* **[tachyon-lists](https://github.com/Dushnilin/tachyon-lists)** — automated multi-source compiler and deduplicator for 143 domain and subnet categories (`.trs`, `.srs`, `.json`, `.lst`).
* **[FPTN (@fptn-project)](https://github.com/fptn-project/fptn)** — L3 packet tunnel over WebSocket/TLS.

---

## Support Development

If Tachyon is useful in your network setup, you can support ongoing development:

* **Boosty:** [boosty.to/tachyon](https://boosty.to/tachyon)
* **SBP (Ozon Bank):** [finance.ozon.ru/apps/sbp/ozonbankpay/019af2ed-d158-77a9-a698-2805a5e61be5](https://finance.ozon.ru/apps/sbp/ozonbankpay/019af2ed-d158-77a9-a698-2805a5e61be5)
* **Bank Cards / SBP (CloudTips):** [pay.cloudtips.ru/p/449c5ef9](https://pay.cloudtips.ru/p/449c5ef9)
* **Bitcoin (BTC):** `bc1q9ehdv7y9g948jejyflkq7xmau3tytgunxgh35h`
* **Ethereum (ETH / ERC-20):** `0x6CB7a4547eD62EF64990D5C6B5D9fdA58EB223E6`
* **TON:** `UQDPhLRjMz5KltDLACAT3YXXHDVEtIDOHky2i33ZIOtsMEoR`
* **Solana (SOL):** `3csTGaNeU9KjhCKHEKAU3XLS5UfVjEeBVhXihpsETZwh`

---

## Legal Notice & Disclaimer

**Disclaimer:**

1. **Purpose of the Software.** `Tachyon` is a general-purpose technical networking utility designed for network traffic routing, load balancing, network diagnostics, information security, and establishing secure corporate or personal communication channels (VPN) on OpenWrt routers.
2. **Compliance with Applicable Laws.** The Software was not created, is not intended, and is not distributed for the purpose of violating the laws of the Russian Federation (including Federal Law No. 149-FZ) or any other jurisdiction, nor for obtaining unauthorized access to restricted information resources.
3. **Use at Your Own Risk.** The author and copyright holder do not provide any proxy/VPN servers, network nodes, subscriptions, access keys, or routing lists. The Software is provided `"AS IS"` without warranty of any kind. Any installation, configuration, and operation of the Software is performed by the user strictly on their own initiative, at their own risk, and under their sole responsibility. The copyright holder assumes no liability for user actions, configurations, or any consequences arising from the use of the Software.
