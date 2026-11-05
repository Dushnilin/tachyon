# 13. HTTP REST Agent API & Model Context Protocol (MCP) Specification

Tachyon provides a standardized RESTful Agent API (`service/agent_api.uc`) and Model Context Protocol JSON-RPC 2.0 server (`service/agent_mcp.uc`), enabling autonomous LLM agents (ChatGPT Actions, Claude Code, Cursor, Windsurf, Open-WebUI, N8N, Dify) to inspect, diagnose, and manage the router with strict privacy redaction.

---

## 1. Endpoints & Transports

* **REST API Base URL**: `http://<router-ip>/cgi-bin/tachyon-agent/v1` (also accepts `/cgi-bin/tachyon-agent/<endpoint>`)
* **OpenAPI 3.0.3 Schema**: `http://<router-ip>/cgi-bin/tachyon-agent/openapi.json`
* **MCP JSON-RPC 2.0 HTTP**: `POST http://<router-ip>/cgi-bin/tachyon-mcp` (or `POST /cgi-bin/tachyon-agent/v1/mcp`)
* **MCP stdio CLI**: `tachyon-mcp` (invokes `service/agent_mcp.uc stdio`)

---

## 2. Authentication & Privacy Guarantees

1. **Authentication (`settings.agent_api_token`)**:
   * Write operations require `Authorization: Bearer <agent_api_token>`.
   * When `agent_api_token` is configured, MCP calls and write endpoints enforce constant-time token verification (`constant_time_eq`).
2. **Mandatory Privacy Redaction**:
   * Every REST and MCP response passes through `service/support_bundle.uc` (`redact_for_llm`, `redact_string`) and `diagnostics/status.uc` (`tachyon-config-masked`).
   * API keys (`sk-*`, `AIza*`, `gsk_*`, `xai-*`), Bearer tokens, Telegram bot tokens & chat IDs, proxy URIs (`vless://`, `vmess://`, `ss://`, `trojan://`, `hysteria2://`, `wireguard://`, `awg://`, `fptn://`, `warp://`), UUIDs, Reality/WireGuard/AWG keys (`private_key`, `pbk`, `sid`, `crypto_key`), passwords, HWIDs, subscription URL tokens, and client MAC addresses (`[REDACTED_MAC]`) are scrubbed automatically.

---

## 3. REST Endpoint Reference

### 3.1. Read Endpoints (`GET`)
* `GET /health` — Lightweight status of `tachyon-core`/`sing-box`, `dnsmasq`, `nftables`, and WAN.
* `GET /snapshot` — Full redacted system snapshot (system info, diagnostics, quick fixes, watchdog status, masked config summary).
* `GET /diagnose` — Structured Local Rule Doctor checks (`diagnose_json`) and suggested quick-fix codes.
* `GET /logs` — Recent system logs (`tachyon|sing-box|zapret|nfqws|byedpi|ciadpi|dnsmasq`) with secret/MAC redaction.
* `GET /config` — Masked UCI `/etc/config/tachyon` dump (`tachyon-config-masked`).
* `GET /docs/search?q=<query>&limit=5` — Searches the built-in RAG knowledge base (`/usr/lib/tachyon/rag_index.json`) via `diagnostics/rag.uc`.
* `GET /route/explain?target=<domain_or_ip>&client_ip=<ip>&port=443&proto=tcp` — Simulates packet & DNS path through `dnsmasq`, FakeIP, `inet TachyonTable`, `ip rule`, and matched `section`/`condition`/`outbound_source`/`balancer`.
* `GET /known-good?action=status` — Inspects Last Known Good (`known_good.uc`) snapshot and observation window state.
* `GET /ai-doctor/last` — Returns the most recent redacted AI Doctor report (`/tmp/ai_doctor_last.json`).
* `GET /tools` — Exports all agent tools in OpenAI Function Calling & MCP format.
* `GET /openapi.json` — Live OpenAPI 3.0.3 specification.

### 3.2. Write & Action Endpoints (`POST`, requires `Authorization: Bearer <token>`)
* `POST /ai-doctor` — Runs live LLM AI Doctor analysis (`{"query": "..."}`).
* `POST /ai-doctor/fix` — Applies one or more of the 25 quick-fix codes (`{"fix": "clear_dns_cache,start_singbox"}`).
* `POST /heal` — Runs Watchdog autonomous healing cycle (`ai_heal`).
* `POST /restart` — Restarts `singbox` (`/etc/init.d/tachyon-core`), `tachyon`, or `dnsmasq`.
* `POST /reload` — Soft-reloads Tachyon rules and configuration.
* `POST /config/plan` — Dry-run validation, redacted UCI diff, and restart vs soft-reload impact analysis (`{"changes": [{"section": "...", "option": "...", "value": "..."}]}`).
* `POST /config/set` — Sets a UCI option on `/etc/config/tachyon` (validates key/value, blocks shell metacharacters, commits via `core/transaction.uc`).
* `POST /section/toggle` — Enables or disables a routing `section` (`{"section": "sec_media", "enabled": "1"}`).
* `POST /domain/add` — Adds a domain to a section's atomic `condition` (`user_domains`) and reloads Tachyon.
* `POST /known-good` — Executes `capture`, `promote`, or `rollback` on Last Known Good state.
* `POST /support-bundle` — Generates a SHA-256 verified, redacted diagnostic support bundle archive.

---

## 4. Model Context Protocol (MCP) Specification (`service/agent_mcp.uc`)

### 4.1. MCP Tools (`tools/list` & `tools/call`)

| Tool Name | Mode | Description |
|---|---|---|
| `tachyon_health` | Read | Quick health check of `tachyon-core`/`sing-box`, `dnsmasq`, `nftables`, and WAN. |
| `tachyon_snapshot` | Read | Full redacted system snapshot: system info, diagnostics, watchdog status, masked config. |
| `tachyon_diagnose` | Read | Detailed local rule diagnostic checks with root causes and suggested quick-fix codes. |
| `tachyon_logs` | Read | Recent redacted system logs (`lines`: 1–200). |
| `tachyon_config` | Read | Masked UCI configuration (`/etc/config/tachyon`). |
| `tachyon_route_explain` | Read | Trace how a packet/domain is routed (`target`, `client_ip`, `port`, `proto`). |
| `tachyon_docs_search` | Read | Search the built-in RAG technical knowledge base (22 architecture & troubleshooting guides). |
| `tachyon_config_plan` | Read/Dry-Run | Validate candidate UCI changes, view redacted diff, and check restart/reload impact. |
| `tachyon_apply_fix` | Write | Apply one or more of the 25 quick-fix codes (`fix` string). |
| `tachyon_heal` | Write | Run autonomous Watchdog self-healing cycle. |
| `tachyon_restart` | Write | Restart `singbox`, `tachyon`, or `dnsmasq`. |
| `tachyon_reload` | Write | Soft-reload Tachyon configuration and rules. |
| `tachyon_set_config` | Write | Set a UCI option in `/etc/config/tachyon` (`section`, `option`, `value`, `reload`). |
| `tachyon_toggle_section` | Write | Enable or disable a routing section (`section`, `enabled`). |
| `tachyon_add_domain` | Write | Add a domain to a routing section's condition (`section`, `domain`). |
| `tachyon_ai_doctor` | Write | Run LLM-powered AI Doctor analysis (`query`). |
| `tachyon_known_good` | Read/Write | Query `status` or execute `capture`, `promote`, `rollback` on Last Known Good state. |
| `tachyon_support_bundle` | Read/Export | Generate a redacted diagnostic support bundle archive. |

### 4.2. MCP Embedded Knowledge Resources (`resources/list` & `resources/read`)

| Resource URI | Description |
|---|---|
| `tachyon://knowledge/architecture` | Complete architectural overview: `tachyon-core`/`sing-box`, DNS & FakeIP (`127.0.0.42:53`), `inet TachyonTable` (`:1602`), local providers (`zapret`, `zapret2`, `byedpi`, `wdtt`, `olcrtc`, `fptn`, `tailscale`, `torrserver`), and reliability stack (`watchdog`, `reconciler`, `known_good`, `transaction`, `jobs`, `events`). |
| `tachyon://knowledge/privacy-rules` | Mandatory Zero-Secret-Leakage policy and redaction rules for connected LLMs and MCP agents. |
| `tachyon://knowledge/config-schema` | Complete modular relational UCI schema (`settings`, `section`, `condition`, `outbound_source`, `balancer`, `outbound_group`, `server`, `telegram`, `guest_mode`). |
| `tachyon://knowledge/codebase-map` | Directory structure, ucode module map, key runtime paths, and CLI commands. |
| `tachyon://knowledge/troubleshooting` | Symptom matrix and all 25 automated quick-fix codes. |
| `tachyon://knowledge/faq` | Operational FAQ and step-by-step diagnostic workflows. |
| `tachyon://diagnostics/last` | Most recent redacted AI Doctor report (`/tmp/ai_doctor_last.json`). |
| `tachyon://system/info` | Live system version, capabilities, uptime, and memory telemetry. |
