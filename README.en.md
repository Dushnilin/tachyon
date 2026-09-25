<div align="center">

![Tachyon Banner](assets/readme/hero.svg)

[![Stars](https://img.shields.io/github/stars/Dushnilin/tachyon?style=for-the-badge&color=00F0FF)](https://github.com/Dushnilin/tachyon/stargazers)
[![Releases](https://img.shields.io/github/v/release/Dushnilin/tachyon?style=for-the-badge&color=818CF8)](https://github.com/Dushnilin/tachyon/releases)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-23.05%20%7C%2024.10%20%7C%2025.x%20%7C%20SNAPSHOT-10B981?style=for-the-badge&logo=openwrt)](https://openwrt.org/)
[![Telegram](https://img.shields.io/badge/Telegram-Channel-26A5E4?style=for-the-badge&logo=telegram&logoColor=white)](https://t.me/tachyon_proxy)
[![Boosty](https://img.shields.io/badge/Boosty-Support-FF6A00?style=for-the-badge&logo=boosty&logoColor=white)](https://boosty.to/tachyon)
[![License](https://img.shields.io/github/license/Dushnilin/tachyon?style=for-the-badge&color=C084FC)](LICENSE)

[**🇷🇺 Русский**](README.md) | [**🇬🇧 English**](README.en.md)

</div>

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

## ⚡ About Tachyon

**Tachyon** is an advanced, autonomous network routing, proxy orchestration, and anti-censorship engine designed specifically for **OpenWrt** routers (fully supporting **OpenWrt 23.05, 24.10, 25.x, and SNAPSHOT** builds). Direct fork and evolution of **[Forkop by @ushan0v](https://github.com/ushan0v/forkop)** (formerly **Podkop Plus**) and **[Steer by @xyzmean](https://github.com/xyzmean/steer)**.

Tachyon combines multi-engine routing (**sing-box**, lightweight **Steer**, and hybrid **Steer-Extended**), native **OpenVPN (.ovpn)** client integration, high-speed **FPTN** (Fast Packet Tunnel Network), local hardware DPI bypass engines (**Zapret v1 / Zapret v2 / ByeDPI**), an interactive combinatorial **DPI Strategy Fuzzer v2**, a hardened **Telegram control bot**, and a cutting-edge **AI Stack** (autonomous **AI Doctor v3.0**, offline local diagnostics, **HTTP REST Agent API / OpenAPI 3.0**, and **Model Context Protocol (MCP)** server for autonomous AI agents).

The entire backend logic is written in **ucode** — OpenWrt's native, high-performance C scripting language — delivering instant response times with minimal RAM footprint (starting from 128 MB RAM devices).

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

## 🌐 Architecture & Traffic Pipeline

<div align="center">

![Tachyon Traffic Pipeline](assets/readme/architecture.svg)

</div>

Tachyon intercepts network flows via kernel **nftables** and dispatches requests without unnecessary latency:
1. **Direct WAN**: Local services, national banks, and trusted destinations proceed without proxy overhead (`0 ms overhead`).
2. **Zapret v1 (`nfqws`)**: Basic TCP/UDP packet desynchronization (`fake`, `disorder`, `split2`) directly on router without VPS.
3. **Zapret v2 (`nfqws2`)**: Advanced multi-vector DPI evasion (`multisplit`, `seqovl`, `wsize`, PAWS `tcp_ts`, authentic `blobs`) for YouTube 4K, Discord, and streaming.
4. **ByeDPI (`ciadpi`)**: Local SOCKS5 desync engine with HTTP/TLS SNI payload fragmentation.
5. **Multi-Engine Tunneling & Proxying (sing-box / Steer / FPTN / OpenVPN)**: Censored endpoints and private traffic are routed through modern secure protocols (VLESS Reality, Hysteria2, WireGuard, AmneziaWG, OpenVPN) or high-speed **FPTN** tunnel (`tun-fptn` over WebSocket/TLS with web traffic masquerading). On resource-constrained hardware, **Steer** / **Steer-Extended** takes over with ultra-low memory footprint.
6. **Smart DNS Pipeline**: Isolated DNS processing via FakeIP (`198.18.0.0/15`), DoH/DoT/DoQ with anti-hijack transparent redirection, SmartDNS/`steer-dnsd` integration, and automated failover (DNS Failover).

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

## 🔥 Core Features & Subsystems

### 🧭 1. Multi-Engine Architecture
* **Flexible Routing Engine Selection**:
  * **sing-box Engine**: Full-featured routing and proxy powerhouse supporting all modern protocols, selective routing rules, and FakeIP.
  * **Steer Engine**: Ultra-lightweight routing engine running native `steer` alongside SmartDNS / local DNS resolver (`steer-dnsd`), optimal for routers with limited RAM.
  * **Steer-Extended Engine**: Hybrid orchestration running Steer + Zapret hardware DPI desync (`nfqws`/`nfqws2`) — pure wire-speed DPI bypass without running heavy Go-based proxy processes.
* **1-Click Engine Switching**:
  * Visual Routing Engine card in LuCI and CLI (`tachyon engine_set <name>`) with live progress modal.
  * Automatic reconfiguration of DNS (`smartdns`, `steer-dnsd`, `dnsmasq`), network interfaces, and Netfilter tables during engine migration.
* **List Materialization & Subscription Export (`sub.txt`)**:
  * Automated plain-text `sub.txt` list generation from subscription cache for Steer VLESS outbounds.
  * Direct downloading and compilation of `.lst`/`.txt` plain domain/IP lists into native `rule_set`.

---

### 🛡️ 2. Multi-Protocol Proxying & Advanced Subscriptions
* **sing-box Engine (v1.11 - v1.14+)**:
  * Native support for modern proxy protocols: **VLESS (Reality / gRPC / WS)**, **VMess**, **Shadowsocks**, **Trojan**, **Hysteria2**, and **WireGuard / AmneziaWG (AWG 3.1)**.
  * **Native OpenVPN Endpoint & `.ovpn` File Upload**: Complete built-in OpenVPN client in sing-box (>= 1.14.0) with direct `.ovpn` configuration file upload and validation via LuCI.
* **High-Speed FPTN Engine (`fptn-client-cli`)**:
  * L3 packet tunneling over WebSocket/TLS with effective HTTPS camouflage to bypass restrictive protocol blocks (`tun-fptn`, routing table `4249`).
* **Advanced Subscription Engine & Happ Crypt4**:
  * **Happ Crypt4 Decryption**: Decrypt proprietary and encrypted provider subscriptions.
  * **Dual HWID Header Emulation**: Clean client profile fingerprinting for upstream subscription servers.
  * **TLS Certificate SHA-256 Pinning**: Node certificate SHA-256 hash validation (`pcs`).
  * **Anti-Collapse Shrink Guard**: Prevents working node cache loss when upstream providers return temporary empty or invalid responses.
* **Cloudflare WARP & AmneziaWG Generator (`generate_warp`)**.
* **Multi-Dimensional Selective Routing**: by domains, IP subnets, client MAC/IP addresses, and destination country (GeoIP).

---

### 🌐 3. Smart DNS, DoH/DoT Stack & Leak Protection
* **FakeIP Pool (`198.18.0.0/15`)**: Near-instant connection establishment without waiting for remote DNS responses.
* **Modern DNS Protocols**: DoH (HTTPS), DoT (TLS), DoQ (QUIC), and DNS over HTTP/3.
* **Autonomous DNS Failover (`dns_failover.uc`)**: Continuous upstream probing and zero-downtime failover to backup resolvers.
* **Anti-DNS Hijack**: Transparent kernel-level interception of UDP/TCP port 53 via nftables.
* **DNS Leak Checker**: Built-in verification testing for unencrypted DNS interception by local ISPs.
* **Multi-WAN & Tailscale Network Isolation**: Automatic exemption of VPN tunnels and Tailscale interfaces (`100.64.0.0/10`) from public WAN alarms, preventing false positives.
* **Hosts Sections & Blocklists (Hosts Engine)**: Static DNS overrides (`dns_hosts`), remote blocklist fetching (AdAway, StevenBlack, Antizapret) with automatic GitHub mirror fallback (`jsdelivr`, `gh-proxy`).
* **Interactive DNS Benchmark (`tachyon dns_benchmark`)** with auto-tuning (`dns_autotune`).

---

### ⚡ 4. God-Tier DPI Bypass Strategy Generator & Fuzzer (DPI Fuzzer v2)
* **Modular Fuzzer Architecture (`fuzzer/*`)**: Decomposed into profiling, runner, benchmarking, and strategy modules.
* **Next-Gen Fuzzing (Probe v2 & Stable Scoring)**: Two-stage verification preventing false positives on unstable networks.
* **Curated Strategy Presets from zapret4rocket & homeproxy-hiddify**: Real-world proven strategies against active ISP blocks.
* **Flowseal Strategy Support**: Integrated Flowseal desync patterns for resilient DPI evasion.
* **Custom Multi-Domain Targets**: Test strategies simultaneously across user-specified target domains.
* **PAWS TCP Timestamp Spoofing (`tcp_ts=-600000:tcp_ts_up`)**: RFC 7323 desync with stale TCP timestamps.
* **Authentic Binary Dumps (Blobs)**: `tls_max`, `tls_google`, `tls_gosuslugi`, `tls_sber`, `quic_google`, `discord_udp`, etc.
* **Exact Sequence Overlap (SeqOvl Pattern Overlap)** & **TCP SYN Data (`syndata`)**.
* **286+ Zapret2 strategies, 130 for Zapret v1, 65 for ByeDPI**.
* **Isolated Netfilter Queue (`0x00200000`) & 1-Click Application (`🏆 Best Match`)**.

---

### 🤖 5. AI Doctor v3.0, REST Agent API & MCP Server (AI Stack)
<div align="center">

![AI Doctor Monitor](assets/readme/ai_doctor_showcase.svg)

</div>

* **Tachyon AI Doctor (v3.0)**: Deep modular architecture (`doctor.uc`, `repairs.uc`, `system_info.uc`, `routing.uc`, `dns.uc`).
  * Diagnostics powered by leading LLMs (**OpenAI**, **Claude**, **DeepSeek**) or local models via OpenRouter / Ollama.
  * **Symptom Collapsing**: Intelligently deduplicates and groups cascading failures into root causes.
* **14 Built-in Quick Fix Codes**:
  * Automated repair for sing-box, Steer, nftables, dnsmasq, and resolv.conf.
  * Provider restart (`restart_providers`), DNS cache flush (`flush_dns`).
  * System time synchronization (`fix_system_time`).
  * Conntrack table flush (`flush_conntrack`).
  * Primary DNS circular deadlock resolution (`fix_bootstrap_dns`).
* **Conflict-Resilient Rollback**: Automatically rolls back to the last known healthy state when syntax or configuration errors occur in dnsmasq or nftables.
* **🚨 Emergency Internet Fallback** (`tachyon restore_native_internet`).
* **🔌 Model Context Protocol (MCP) Server (`tachyon mcp`)**: Standard JSON-RPC 2.0 stdio server enabling direct connection to Claude Desktop, Cursor, and Antigravity.
* **🌐 HTTP REST Agent API (OpenAPI 3.0)**: Bearer token authentication, async reload to avoid client HTTP timeouts, and CGI gateway symlink (`/cgi-bin/tachyon-api`).

---

### 📱 6. Interactive Telegram Control Bot
<div align="center">

![Telegram Bot Showcase](assets/readme/telegram_bot_showcase.svg)

</div>

* **Clash API Authentication**: Authenticated management via Secret Token.
* **Extended Telemetry (`/info`)** and on-the-fly section/node routing control.
* **Live Connection Monitor (`/connections`)** with paginated output and emergency reset button (`/close_connections`).
* **Dedicated Worker Process**: Grace period for heartbeats, zombie prevention, and process deduplication.
* **Quiet Hours (`/qh`)** and LAN device access management by MAC address.
* **Commands**: `/doctor`, `/ai_doctor`, `/heal`, `/speed`, `/ping`, `/test`, `/logs`, `/info`, `/export_config`, `/restart`, `/lang`.

---

### 🛡️ 7. Watchdog, Process Identity & Transactional Stability
<div align="center">

![Watchdog Showcase](assets/readme/watchdog_showcase.svg)

</div>

* **Process Identity & PID Provenance (`core/process.uc`)**: Validates `pid`, `starttime`, and `boot_id` before signals are sent, preventing accidental termination of recycled system PIDs.
* **Transactional Package Manager (`core/packages.uc`)**: Stale lock cleanup, ELF header verification of UPX-compressed binaries, and automated APK `world` file scrubbing to eliminate `PROVIDES/REPLACES` upgrade conflicts.
* **Unified Structured Logger (`core/logging.uc`)**: Rotated and structured JSON/syslog logging.
* **Restart-Loop Protection**: Capped at 3 restarts per 10 minutes with `PROXY_RESTART_LOCK` mutex.
* **Memory Optimization (OOM Watchdog)**: Dynamic `GOMEMLIMIT` scaling with Telegram alerts.
* **Seamless Hot-Reload** & **Configuration Snapshots & Rollback** (`snapshot_save` / `snapshot_restore`).

---

### 👶 8. Parental Controls, Quotas & Smart QoS
* **Per-Device Access Scheduling** (specific hours and days of week).
* **Bandwidth & Data Quotas**: Device volume caps with automated cron resets (`parental_quota.uc`).
* **Smart QoS & Priority Daemon**: DSCP packet tagging in nftables prioritizing latency-critical flows (voice, Discord, gaming) and eliminating Bufferbloat.
* **Instant Device Isolation**: 1-click internet cut-off for LAN clients.

---

### 🖥️ 9. Modern LuCI Web Interface (TypeScript)
<div align="center">

![LuCI Web UI Showcase](assets/readme/luci_web_showcase.svg)

</div>

* **Real-Time Memory Telemetry**: Exact RAM usage by Tachyon components and dnsmasq cache estimate on the dashboard.
* **Step-by-Step Update Indicators**: Interactive visual progress for list/subscription updates instead of raw log streams.
* **1-Click Section Clone ("Copy")**: Rapid duplication of complex routing sections.
* **Multi-Engine Switching**: Seamless switcher between `sing-box`, `steer`, and `steer-extended` with progress modal.
* **Built-in `.ovpn` File Uploader** for OpenVPN sections.
* **Integrated Strategy Fuzzer Modal** with live progress bars, HTTP codes, and `🏆 Best Match`.
* **Streaming Terminal Modal** for component installation and rollbacks.

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

## 🛠️ CLI & REST Agent API Reference

<div align="center">

![CLI & API Showcase](assets/readme/cli_showcase.svg)

</div>

```bash
# === Multi-Engine Routing Controls ===
tachyon engine_list                             # List available routing engines (sing-box, steer, steer-extended)
tachyon engine_get                              # Show current active engine
tachyon engine_set <sing-box|steer|steer-extended> # Switch engine with automated reconfiguration
tachyon engine_status                           # Full active engine runtime status (JSON)

# === DPI Strategy Fuzzer & Benchmarks ===
tachyon fuzzer_start youtube_suite zapret2      # Start YouTube bypass benchmark on Zapret2
tachyon fuzzer_start discord_suite zapret2      # Start Discord benchmark (voice + UDP RTC)
tachyon fuzzer_status                           # Current fuzzer progress & results (JSON)
tachyon fuzzer_stop                             # Immediately terminate fuzzer & clean Netfilter
tachyon fuzzer_apply <strategy_id>              # Apply winning strategy to UCI configuration

# === DNS Testing & Network Stack ===
tachyon dns_benchmark                           # Benchmark latency & reachability of DNS resolvers
tachyon dns_autotune --apply                    # Auto-select and apply the fastest DNS resolver
tachyon test_rule google.com                    # Test which routing section matches a domain/IP

# === System & Offline Diagnostics ===
tachyon doctor                                  # Run local diagnostics without LLM
tachyon ai_doctor                               # Run AI Doctor analysis (with LLM)
tachyon ai_doctor_last                          # View last saved AI report
tachyon apply_quick_fix clear_dns_cache         # Apply specific quick fix code
tachyon diagnose_json                           # Output full diagnostic state snapshot (JSON)

# === Emergency Internet Fallback ===
tachyon restore_native_internet                 # Stop proxy and cleanly restore pure WAN internet

# === Telegram Bot Management ===
tachyon telegram_status                         # Check Telegram bot daemon running state
tachyon telegram_diagnose                       # Run Telegram connection diagnostics (JSON)
tachyon telegram_start                          # Start Telegram bot worker
tachyon telegram_stop                           # Stop Telegram bot worker

# === Snapshots & Backups ===
tachyon snapshot_list                           # List saved configuration snapshots
tachyon snapshot_save my_working_setup          # Create a named configuration snapshot
tachyon snapshot_restore /etc/config/snap.json  # Restore configuration from snapshot
tachyon backup                                  # Create full configuration backup archive

# === Rule Lists & Subscriptions ===
tachyon list_update                             # Force update remote domain and IP lists
tachyon subscription_update                     # Update all proxy subscriptions
tachyon hosts_list_update                       # Download and update remote Hosts blocklists

# === Service Management & Watchdog ===
tachyon ai_heal                                 # Trigger manual self-healing cycle
tachyon ai_status                               # View concise Watchdog status
tachyon ai_status_full                          # View full Watchdog metrics (JSON)

# === Profile Generators ===
tachyon generate_warp                           # Generate Cloudflare WARP WireGuard configuration
tachyon generate_reality_keypair                # Generate public/private keypair for VLESS Reality

# === AI Integration (MCP & HTTP REST API) ===
tachyon mcp                                     # Start Model Context Protocol server (stdio)
curl http://192.168.1.1/cgi-bin/tachyon-api/health
curl http://192.168.1.1/cgi-bin/tachyon-api/openapi.json
```

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

## 💻 Installation

<div align="center">

![Installation Terminal](assets/readme/install_terminal.svg)

</div>

Run the following single command in your router's SSH terminal:

```bash
wget -O /tmp/tachyon-setup.sh https://raw.githubusercontent.com/Dushnilin/tachyon/main/install.sh && sh /tmp/tachyon-setup.sh
```

> [!TIP]
> **Installation Mirrors (if direct access to GitHub is blocked or throttled):**
> ```bash
> # Mirror 1 (jsdelivr.net CDN):
> wget -O /tmp/tachyon-setup.sh https://cdn.jsdelivr.net/gh/Dushnilin/tachyon@main/install.sh && sh /tmp/tachyon-setup.sh
> 
> # Mirror 2 (gh-proxy.com):
> wget -O /tmp/tachyon-setup.sh https://gh-proxy.com/raw.githubusercontent.com/Dushnilin/tachyon/main/install.sh && sh /tmp/tachyon-setup.sh
> 
> # Mirror 3 (ghfast.top):
> wget -O /tmp/tachyon-setup.sh https://ghfast.top/https://raw.githubusercontent.com/Dushnilin/tachyon/main/install.sh && sh /tmp/tachyon-setup.sh
> ```

> [!NOTE]
> **Automatic Migration:** Existing configurations from **Forkop**, **Podkop Plus**, or original **Podkop** are fully compatible. The installer will automatically migrate your settings to `/etc/config/tachyon` without data loss.

### 🗑️ Uninstallation (Clean Uninstall & Backup)

To cleanly remove Tachyon, restore stock DNS, flush nftables rules, and preserve your configuration in `/etc/config/tachyon.backup-<timestamp>`:

```bash
wget -O /tmp/tachyon-uninstall.sh https://raw.githubusercontent.com/Dushnilin/tachyon/main/uninstall.sh && sh /tmp/tachyon-uninstall.sh
```

*Via mirrors:*
```bash
# Mirror 1 (jsdelivr.net CDN):
wget -O /tmp/tachyon-uninstall.sh https://cdn.jsdelivr.net/gh/Dushnilin/tachyon@main/uninstall.sh && sh /tmp/tachyon-uninstall.sh

# Mirror 2 (gh-proxy.com):
wget -O /tmp/tachyon-uninstall.sh https://gh-proxy.com/raw.githubusercontent.com/Dushnilin/tachyon/main/uninstall.sh && sh /tmp/tachyon-uninstall.sh
```

**Options & Flags:**
* `-y`, `--yes` — non-interactive mode without confirmation prompts.
* `-p`, `--purge` — completely remove all files including configurations and backups.
* `--keep-binaries` — keep sing-box / zapret / byedpi binaries in `/usr/bin/`.

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

## 🤝 Upstream Projects & Credits

Tachyon stands on the shoulders of incredible open-source projects:

* 🍴 **[Forkop (ushan0v)](https://github.com/ushan0v/forkop)** — Direct parent repository (formerly Podkop Plus).
* 🐕 **[Podkop (itdoginfo)](https://github.com/itdoginfo/podkop)** — The original project that inspired the architecture.
* 🧭 **[steer (xyzmean)](https://github.com/xyzmean/steer)** — Original lightweight policy-based routing and bypass project for OpenWrt, integrated into the Multi-Engine core.
* 📦 **[sing-box](https://github.com/SagerNet/sing-box)** — Universal proxy engine.
* 🚀 **[zapret (bol-van)](https://github.com/bol-van/zapret2)** — DPI desync framework (`nfqws` / `nfqws2`).
* 🌐 **[ByeDPI](https://github.com/hrbrmstr/byedpi)** — Local SOCKS desync proxy.
* 🛡️ **[FPTN (fptn-project)](https://github.com/fptn-project/fptn)** — High-speed VPN & packet tunnel over WebSocket/TLS with DPI evasion.

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

## 💖 Support & Donations

If Tachyon powers your daily networking and keeps your connection fast and secure, consider supporting ongoing development! ☕ 🧀 🌭

⭐ **Boosty (subscriptions, donations, exclusives):**  
👉 [**Support on Boosty**](https://boosty.to/tachyon)

💳 **Credit Cards / SBP / Tinkoff Pay:**  
👉 [**Support the project via CloudTips**](https://pay.cloudtips.ru/p/48c57581)

🪙 **Cryptocurrency:**
* **Bitcoin (BTC):** `bc1q9ehdv7y9g948jejyflkq7xmau3tytgunxgh35h`
* **Ethereum (ETH / ERC-20):** `0x6CB7a4547eD62EF64990D5C6B5D9fdA58EB223E6`
* **TON:** `UQDPhLRjMz5KltDLACAT3YXXHDVEtIDOHky2i33ZIOtsMEoR`
* **Solana (SOL):** `3csTGaNeU9KjhCKHEKAU3XLS5UfVjEeBVhXihpsETZwh`

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

<div align="center">

![Tachyon Community Footer](assets/readme/footer_tachyon.svg)

</div>
