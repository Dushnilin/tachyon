<div align="center">

![Tachyon Banner](assets/readme/hero.svg)

[![Stars](https://img.shields.io/github/stars/Dushnilin/tachyon?style=for-the-badge&color=38BDF8)](https://github.com/Dushnilin/tachyon/stargazers)
[![Releases](https://img.shields.io/github/v/release/Dushnilin/tachyon?style=for-the-badge&color=818CF8)](https://github.com/Dushnilin/tachyon/releases)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-23.05%20%7C%2024.10%20%7C%2025.x%20%7C%20SNAPSHOT-10B981?style=for-the-badge&logo=openwrt)](https://openwrt.org/)
[![License](https://img.shields.io/github/license/Dushnilin/tachyon?style=for-the-badge&color=C084FC)](LICENSE)

[**🇷🇺 Русский**](README.md) | [**🇬🇧 English**](README.en.md)

</div>

---

## ⚡ About Tachyon

**Tachyon** is an advanced, autonomous network routing, proxy orchestration, and anti-censorship engine designed specifically for **OpenWrt** routers (fully supporting **OpenWrt 23.05, 24.10, 25.x, and SNAPSHOT** builds). Direct fork of **[Forkop by @ushan0v](https://github.com/ushan0v/forkop)** (formerly **Podkop Plus**).

Tachyon combines the power of **sing-box**, local DPI bypass engines (**Zapret v1 / Zapret v2 / ByeDPI**), an interactive **Telegram bot**, and a cutting-edge **2026 AI Stack** (autonomous **AI Doctor** & **HTTP REST Agent API / OpenAPI 3.0**).

The entire backend logic is written in **ucode** — OpenWrt's native, lightweight scripting language — delivering instant response times with minimal RAM footprint (starting from 128 MB RAM devices).

---

## 🔥 Core Features & Architecture

### 🛡️ 1. Multi-Protocol Proxying & Local DPI Bypass
* **sing-box Engine**: Native support for modern proxy protocols — **VLESS (Reality / gRPC / WS)**, **VMess**, **Shadowsocks**, **Trojan**, and **WireGuard**.
* **Local DPI Bypass Without External VPS**: 
  * Full built-in integration with **Zapret v1 (`nfqws`)**, **Zapret v2 (`nfqws2`)**, and **ByeDPI (`ciadpi`)** desync engines for local packet manipulation directly on the router.
* **Multi-Dimensional Selective Routing**: 
  * **By Domains & IP Subnets**: Route only target traffic through proxies or desync engines.
  * **By Client Devices (MAC / IP)**: Per-device routing rules for Smart TVs, smartphones, PCs, and gaming consoles.
  * **By GeoIP & Countries**: Flexible inclusion/exclusion list controls based on destination country.
* **Automated Subscription Updates**: Background fetching, parsing, and node rotation from remote subscription URLs.

---

### 🤖 2. AI Doctor & HTTP REST Agent API (2026 AI Stack)
* **Tachyon AI Doctor (v2)**: Advanced AI diagnostic engine supporting modern LLMs (**OpenAI**, **Anthropic Claude**, **DeepSeek**, or local models via OpenRouter / Ollama).
  * **Deep Contextual Intelligence**: Feeds real-time service health, Watchdog failure history (OOM events, error streaks), and compressed system logs into the LLM prompt.
  * **Multi-Fix Execution Chains**: Generates multi-action repair sequences with dedicated UI buttons per fix or a single "Fix All" action.
  * **13 Built-in Quick Fix Codes**: Automated repairs for sing-box, nftables, dnsmasq, resolv.conf, DNS cache clearing, subscription refreshing, and network stack restarts.
  * **Language Modes**: Configurable diagnosis output language (`ru` / `en`).
* **🤖 Interactive Telegram Commands (`/ai_doctor` & `/fix`)**:
  * Trigger AI diagnostics directly from Telegram using `/ai_doctor` with interactive Inline Keyboards for instant quick-fix execution.
* **🌐 HTTP REST Agent API & OpenAPI 3.0 (Swagger)**:
  * Full-featured API at `/cgi-bin/tachyon-agent/` with granular READ/WRITE permission controls secured by a Bearer token (`agent_api_token`).
  * Native **OpenAPI 3.0.3** spec (`GET /cgi-bin/tachyon-agent/openapi.json`) for seamless integration with **ChatGPT Custom GPTs**, N8N, Dify, Flowise, and autonomous LLM agents (Cursor, AutoGPT, Claude Code).

---

### 📱 3. Interactive Telegram Control Bot
A feature-rich control center right inside your messenger:
* **Live Rule Management**: View active routing lists and instantly add new domains or IP subnets on the fly.
* **Instant Toggle**: Enable or disable routing sections with a single button.
* **Server Selection & Latency**: Switch active proxy nodes with live RTT ping measurements.
* **Device Access Control**: View active DHCP clients and block/unblock internet access by MAC address.
* **Diagnostics & Commands**: `/doctor`, `/ai_doctor`, `/fix <code_name>`, `/restart`, `/backup`.

---

### 🛡️ 4. Watchdog — Protection & Self-Healing System
Watchdog is the heart of Tachyon's stability, running every 5–15 seconds without external dependencies:
* **Atomic Operations & UCI Backups**: Configuration writes via `tmp` + `mv` prevent file corruption during sudden power losses.
* **Restart-Loop Protection**: Maximum 3 restarts per 10 minutes (`safe_proxy_restart()`), `PROXY_RESTART_LOCK` mutex, and DNS query loop cooldowns.
* **Memory Optimization (OOM Watchdog)**: Dynamic `GOMEMLIMIT` adjustment under memory pressure with automated Telegram alerts.
* **Seamless Hot-Reload**: Rule updates and server switches apply softly without dropping active TCP connections (Discord calls, gaming, and downloads remain uninterrupted).
* **WAN & Gateway Recovery**: Active interface monitoring and automated route recovery during ISP outages.

---

### 🖥️ 5. Modern Web Interface (LuCI - TypeScript)
* Native integration into OpenWrt's LuCI dashboard.
* **Interactive Dashboard**: Real-time latency tracking, subscription manager, rule editor, and service controls in a few clicks.
* **Dynamic Repository Links**: Component cards link directly to the installed variant's GitHub repository (extended, lx, stable).
* **Commit-Level Update Tracking**: Alerts for newer commits within the same release tag.

---

## 🛠️ CLI & API Quick Reference

```bash
# === System Diagnostics ===
tachyon doctor                            # Run local diagnostics without LLM
tachyon ai_doctor                         # Run AI Doctor analysis (with LLM)
tachyon ai_doctor_last                    # View last saved AI report
tachyon apply_quick_fix clear_dns_cache   # Apply specific quick fix code
tachyon diagnose_json                     # Output full diagnostic JSON

# === Service Management & Watchdog ===
tachyon ai_heal                           # Trigger manual self-healing cycle
tachyon ai_status                         # View concise Watchdog status
tachyon ai_status_full                    # View full Watchdog metrics

# === HTTP REST API Checks ===
curl http://192.168.1.1/cgi-bin/tachyon-agent/health
curl http://192.168.1.1/cgi-bin/tachyon-agent/openapi.json
```

---

## 💻 Installation

Run the following single command in your router's SSH terminal:

```bash
sh <(wget -O - https://raw.githubusercontent.com/Dushnilin/tachyon/main/install.sh)
```

> [!NOTE]
> **Automatic Migration:** Existing configurations from **Forkop**, **Podkop Plus**, or original **Podkop** are fully compatible. The installer will automatically migrate your settings to `/etc/config/tachyon` without data loss.

---

## 🤝 Upstream Projects & Credits

Tachyon stands on the shoulders of incredible open-source projects:

* 🍴 **[Forkop (ushan0v)](https://github.com/ushan0v/forkop)** — Direct parent repository (formerly Podkop Plus).
* 🐕 **[Podkop (itdoginfo)](https://github.com/itdoginfo/podkop)** — The original project that inspired the architecture.
* 📦 **[sing-box](https://github.com/SagerNet/sing-box)** — Universal proxy engine.
* 🚀 **[zapret (bol-van)](https://github.com/bol-van/zapret2)** — DPI desync framework (`nfqws` / `nfqws2`).
* 🌐 **[ByeDPI](https://github.com/hrbrmstr/byedpi)** — Local SOCKS desync proxy.

---

## 💖 Support & Donations

If Tachyon powers your daily networking and keeps your connection fast and secure, consider supporting ongoing development! ☕ 🧀 🌭

💳 **Credit Cards / SBP / Tinkoff Pay:**  
👉 [**Support the project via CloudTips**](https://pay.cloudtips.ru/p/48c57581)

---

<div align="center">

Made with ❤️ for OpenWrt Community

</div>
