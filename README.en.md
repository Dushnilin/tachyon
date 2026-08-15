<div align="center">

![Tachyon Banner](assets/readme/hero.svg)

[![Stars](https://img.shields.io/github/stars/Dushnilin/tachyon?style=for-the-badge&color=00F0FF)](https://github.com/Dushnilin/tachyon/stargazers)
[![Releases](https://img.shields.io/github/v/release/Dushnilin/tachyon?style=for-the-badge&color=818CF8)](https://github.com/Dushnilin/tachyon/releases)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-23.05%20%7C%2024.10%20%7C%2025.x%20%7C%20SNAPSHOT-10B981?style=for-the-badge&logo=openwrt)](https://openwrt.org/)
[![License](https://img.shields.io/github/license/Dushnilin/tachyon?style=for-the-badge&color=C084FC)](LICENSE)

[**🇷🇺 Русский**](README.md) | [**🇬🇧 English**](README.en.md)

</div>

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

## ⚡ About Tachyon

**Tachyon** is an advanced, autonomous network routing, proxy orchestration, and anti-censorship engine designed specifically for **OpenWrt** routers (fully supporting **OpenWrt 23.05, 24.10, 25.x, and SNAPSHOT** builds). Direct fork of **[Forkop by @ushan0v](https://github.com/ushan0v/forkop)** (formerly **Podkop Plus**).

Tachyon combines the power of **sing-box**, local hardware DPI bypass engines (**Zapret v1 / Zapret v2 / ByeDPI**), an interactive **Telegram bot**, and a cutting-edge **AI Stack** (autonomous **AI Doctor v2.5** with offline local diagnostics & **HTTP REST Agent API / OpenAPI 3.0**).

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
3. **Zapret v2 (`nfqws2`)**: Advanced multi-vector DPI evasion (`multisplit`, `seqovl`, `wsize`) for YouTube 4K and Discord.
4. **ByeDPI (`ciadpi`)**: Local SOCKS5 desync engine with HTTP/TLS SNI payload fragmentation.
5. **Encrypted Proxy Tunnel (sing-box)**: Censored endpoints and private traffic are routed through modern protocols (VLESS Reality, Hysteria2, WireGuard).

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

## 🔥 Core Features & Subsystems

### 🛡️ 1. Multi-Protocol Proxying & Local DPI Bypass
* **sing-box Engine (v1.11+)**: Native support for modern proxy protocols — **VLESS (Reality / gRPC / WS)**, **VMess**, **Shadowsocks**, **Trojan**, **Hysteria2**, and **WireGuard / AmneziaWG**.
* **Local DPI Bypass Without External VPS**: 
  * Full built-in integration with **Zapret v1 (`nfqws`)**, **Zapret v2 (`nfqws2`)**, and **ByeDPI (`ciadpi`)** desync engines for hardware TCP segment manipulation.
* **Multi-Dimensional Selective Routing**: 
  * **By Domains & IP Subnets**: Route only target traffic through proxies or desync engines.
  * **By Client Devices (MAC / IP)**: Per-device routing rules for Smart TVs, smartphones, PCs, and gaming consoles.
  * **By GeoIP & Countries**: Flexible inclusion/exclusion list controls based on destination country.
* **Automated Subscription Updates**: Background fetching, parsing, and node rotation from remote subscription URLs with automated latency (RTT) testing.

#### 🌐 Hosts Sections & DNS Overrides (Hosts Engine)
* **Static DNS Overriding (`dns_hosts`)**: Direct mapping of domains to static IP addresses in sing-box DNS and dnsmasq without editing `/etc/hosts`.
* **Remote Hosts Lists Ingestion (`hosts_list_urls`)**: Automatic background downloading and parsing of external host lists and blocklists (AdAway, StevenBlack, custom blocklists).
* **Unified Cache (`combined.txt`)**: High-performance deduplication, merging, and global caching of multiple remote host sources into a single lightweight cache.
* **GitHub Mirror Failover**: Resilient downloads that automatically retry via mirrors (`gh-proxy.com`, `ghproxy.net`) if direct access to github.com is blocked or throttled.
* **Hosts-Only Action Sections (`action = hosts`)**: Dedicated routing sections operating purely as DNS override engines without requiring an outbound proxy association.

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

### 🤖 2. AI Doctor & HTTP REST Agent API (AI Stack v2.5)

<div align="center">

![AI Doctor Monitor](assets/readme/ai_doctor_showcase.svg)

</div>

* **Tachyon AI Doctor (v2.5)**: Deep AI diagnostic engine supporting modern LLMs (**OpenAI**, **Anthropic Claude**, **DeepSeek**, or local models via OpenRouter / Ollama).
  * **Deep Contextual Intelligence**: Feeds real-time service health, Watchdog failure history (OOM events, error streaks), and compressed system logs into the LLM prompt.
  * **Multi-Fix Execution Chains**: Generates multi-action repair sequences with dedicated UI buttons per fix or a single "Fix All" action.
* **🩺 Offline Local Rule Doctor**:
  * **13 Built-in Quick Fix Codes**: Automated repairs for sing-box, nftables, dnsmasq, resolv.conf, DNS cache clearing, subscription refreshing, and network stack restarts.
  * **NTP Time Synchronization (`fix_system_time`)**: Automatic detection and recovery from system clock desync.
  * **Conntrack Table Flush (`flush_conntrack`)**: Clears connection tracking tables during network storms.
  * **DNS Dead-lock Repair (`fix_bootstrap_dns`)**: Prevents circular deadlock on sing-box primary bootstrap resolvers.
  * **Tunnel MTU Optimization (`optimize_mtu`)**: Automatic MTU tuning for WireGuard / AmneziaWG tunnels.
* **🚨 Emergency Native Internet Fallback**:
  * Instant 1-click restore of clean WAN internet via UI or `tachyon restore_native_internet` CLI command without rebooting the router.

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

### 📱 3. Interactive Telegram Control Bot

<div align="center">

![Telegram Bot Showcase](assets/readme/telegram_bot_showcase.svg)

</div>

A feature-rich control center right inside your messenger:
* **Live Rule Management**: View active routing lists and instantly add new domains or IP subnets on the fly.
* **Instant Toggle**: Enable or disable routing sections with a single button.
* **Server Selection & Latency**: Switch active proxy nodes with live RTT ping measurements.
* **Device Access Control**: View active DHCP clients and block/unblock internet access by MAC address.
* **Diagnostics & Commands**: `/doctor`, `/ai_doctor`, `/fix <code_name>`, `/restart`, `/backup`, `/status`.

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

### 🛡️ 4. Watchdog — Protection & Self-Healing System

<div align="center">

![Watchdog Showcase](assets/readme/watchdog_showcase.svg)

</div>

Watchdog is the heart of Tachyon's stability, running every 5–15 seconds without external dependencies:
* **Atomic Operations & UCI Backups**: Configuration writes via `tmp` + `mv` prevent file corruption during sudden power losses.
* **Restart-Loop Protection**: Maximum 3 restarts per 10 minutes (`safe_proxy_restart()`), `PROXY_RESTART_LOCK` mutex, and DNS query loop cooldowns.
* **Memory Optimization (OOM Watchdog)**: Dynamic `GOMEMLIMIT` adjustment under memory pressure with automated Telegram alerts.
* **Seamless Hot-Reload**: Rule updates and server switches apply softly without dropping active TCP connections (Discord calls, gaming, and downloads remain uninterrupted).
* **WAN & Gateway Recovery**: Active interface monitoring and automated route recovery during ISP outages.

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

### 🖥️ 5. Modern Web Interface (LuCI - TypeScript)

<div align="center">

![LuCI Web UI Showcase](assets/readme/luci_web_showcase.svg)

</div>

* Native integration into OpenWrt's LuCI dashboard.
* **Interactive Dashboard**: Real-time latency tracking, subscription manager, rule editor, and service controls in a few clicks.
* **Streaming Terminal Modal**: Real-time console logs for component installations and updates without UI freezes.
* **Dynamic Repository Links**: Component cards link directly to the installed variant's GitHub repository (extended, lx, stable).
* **Commit-Level Update Tracking**: Alerts for newer commits within the same release tag.

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

## 🛠️ CLI & REST Agent API Reference

<div align="center">

![CLI & API Showcase](assets/readme/cli_showcase.svg)

</div>

```bash
# === System & Offline Diagnostics ===
tachyon doctor                            # Run local diagnostics without LLM
tachyon ai_doctor                         # Run AI Doctor analysis (with LLM)
tachyon ai_doctor_last                    # View last saved AI report
tachyon apply_quick_fix clear_dns_cache   # Apply specific quick fix code
tachyon diagnose_json                     # Output full diagnostic JSON

# === Emergency Internet Fallback ===
tachyon restore_native_internet           # Stop proxy and cleanly restore pure WAN internet

# === Service Management & Watchdog ===
tachyon ai_heal                           # Trigger manual self-healing cycle
tachyon ai_status                         # View concise Watchdog status
tachyon ai_status_full                    # View full Watchdog metrics

# === HTTP REST API Checks ===
curl http://192.168.1.1/cgi-bin/tachyon-agent/health
curl http://192.168.1.1/cgi-bin/tachyon-agent/openapi.json
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
sh <(wget -O - https://raw.githubusercontent.com/Dushnilin/tachyon/main/install.sh)
```

> [!NOTE]
> **Automatic Migration:** Existing configurations from **Forkop**, **Podkop Plus**, or original **Podkop** are fully compatible. The installer will automatically migrate your settings to `/etc/config/tachyon` without data loss.

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

## 🤝 Upstream Projects & Credits

Tachyon stands on the shoulders of incredible open-source projects:

* 🍴 **[Forkop (ushan0v)](https://github.com/ushan0v/forkop)** — Direct parent repository (formerly Podkop Plus).
* 🐕 **[Podkop (itdoginfo)](https://github.com/itdoginfo/podkop)** — The original project that inspired the architecture.
* 📦 **[sing-box](https://github.com/SagerNet/sing-box)** — Universal proxy engine.
* 🚀 **[zapret (bol-van)](https://github.com/bol-van/zapret2)** — DPI desync framework (`nfqws` / `nfqws2`).
* 🌐 **[ByeDPI](https://github.com/hrbrmstr/byedpi)** — Local SOCKS desync proxy.

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

## 💖 Support & Donations

If Tachyon powers your daily networking and keeps your connection fast and secure, consider supporting ongoing development! ☕ 🧀 🌭

💳 **Credit Cards / SBP / Tinkoff Pay:**  
👉 [**Support the project via CloudTips**](https://pay.cloudtips.ru/p/48c57581)

<p align="center">
  <img src="assets/readme/divider_stream.svg" width="100%" alt="divider" />
</p>

<div align="center">

![Tachyon Community Footer](assets/readme/footer_tachyon.svg)

</div>
