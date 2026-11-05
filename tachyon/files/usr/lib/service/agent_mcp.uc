#!/usr/bin/env ucode

// ─── Tachyon MCP Server ─────────────────────────────────────────────────────
//
// Model Context Protocol (MCP) server for Tachyon on OpenWrt.
// Transport: JSON-RPC 2.0 over stdio (newline-delimited).
//
// Usage: ucode -L /usr/lib/tachyon /usr/lib/tachyon/service/agent_mcp.uc
// Or:    tachyon mcp
//
// MCP Spec: https://modelcontextprotocol.io/specification/2025-11-25
// Protocol: JSON-RPC 2.0 over stdio

let fs = require("fs");
let uci = require("core.uci");
let common = require("core.common");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const RUNTIME_UC = LIB_DIR + "/diagnostics/runtime.uc";
const WATCHDOG_UC = LIB_DIR + "/service/watchdog.uc";
const MCP_PROTOCOL_VERSION = "2025-11-25";
const SERVER_NAME = "tachyon-mcp";
const SERVER_VERSION = getenv("TACHYON_VERSION") || "dev";

let as_string = common.as_string;
let shell_quote = common.shell_quote;

function trim(value) {
    return value == null ? "" : replace(as_string(value), /^\s+|\s+$/g, "");
}

// ─── Helpers ────────────────────────────────────────────────────────────────

let write_json = common.write_json;

function write_rpc_response(id, result) {
    write_json({ jsonrpc: "2.0", id: id, result: result });
}

function write_rpc_error(id, code, message, data) {
    let err_obj = { jsonrpc: "2.0", id: id, error: { code: code, message: message } };
    if (data != null) err_obj.error.data = data;
    write_json(err_obj);
}

function command_capture(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe) return { status: 1, output: "" };
    let data = pipe.read("all");
    let status = common.normalize_status(pipe.close());
    return { status: status, output: data == null ? "" : as_string(data) };
}

let command_output = common.command_output;

function module_capture(args) {
    let parts = ["ucode", "-L", shell_quote(LIB_DIR), shell_quote(RUNTIME_UC)];
    for (let a in args) push(parts, shell_quote(as_string(a)));
    return command_capture(join(" ", parts));
}

function parse_json_safe(raw) {
    try { return json(as_string(raw)); } catch(e) { return null; }
}

function read_file(path) {
    let data = fs.readfile(as_string(path));
    return data == null ? "" : as_string(data);
}

let read_json_file = common.read_json_file;

let _sb_mod = null;
function sb_mod() {
    if (_sb_mod == null) {
        try { _sb_mod = require("service.support_bundle"); } catch (e) { _sb_mod = false; }
    }
    return _sb_mod || null;
}

function redact_text(str) {
    if (str == null || str == "") return "";
    let s = as_string(str);
    let sb = sb_mod();
    if (sb && sb.redact_for_llm)
        return sb.redact_for_llm(s);
    if (sb && sb.redact_string)
        return sb.redact_string(s);
    return s;
}

function redact_obj(val) {
    let sb = sb_mod();
    if (sb && sb.redact_object)
        return sb.redact_object(val);
    let t = type(val);
    if (t == "string") return redact_text(val);
    if (t == "array") {
        let out = [];
        for (let item in val) push(out, redact_obj(item));
        return out;
    }
    if (t == "object") {
        let out = {};
        for (let k, v in val) out[k] = redact_obj(v);
        return out;
    }
    return val;
}

// ─── Tool Definitions ───────────────────────────────────────────────────────

let TOOLS = [
    {
        name: "tachyon_health",
        description: "Quick health status of all Tachyon services (sing-box, watchdog). Returns running/stopped state, incidents count.",
        inputSchema: { type: "object", properties: {} },
        annotations: { readOnlyHint: true }
    },
    {
        name: "tachyon_snapshot",
        description: "Full system snapshot: services, connectivity, sections, logs, memory. Use this first for initial assessment.",
        inputSchema: { type: "object", properties: {} },
        annotations: { readOnlyHint: true }
    },
    {
        name: "tachyon_diagnose",
        description: "Run full self-diagnostics. Returns structured problem list with severity and suggested fixes. Auto-repairs detected issues.",
        inputSchema: { type: "object", properties: {} },
        annotations: { readOnlyHint: true }
    },
    {
        name: "tachyon_logs",
        description: "Get last 100 Tachyon-related syslog lines.",
        inputSchema: { type: "object", properties: {} },
        annotations: { readOnlyHint: true }
    },
    {
        name: "tachyon_config",
        description: "Get current UCI configuration (secrets masked).",
        inputSchema: { type: "object", properties: {} },
        annotations: { readOnlyHint: true }
    },
    {
        name: "tachyon_heal",
        description: "Run automatic self-healing: diagnose + fix all detected issues.",
        inputSchema: { type: "object", properties: {} },
        annotations: { readOnlyHint: false, destructiveHint: false }
    },
    {
        name: "tachyon_restart",
        description: "Restart a subsystem: singbox | tachyon | dnsmasq | watchdog.",
        inputSchema: {
            type: "object",
            required: ["service"],
            properties: {
                service: {
                    type: "string",
                    enum: ["singbox", "tachyon", "dnsmasq", "watchdog"],
                    description: "Service to restart"
                }
            }
        },
        annotations: { readOnlyHint: false, destructiveHint: true }
    },
    {
        name: "tachyon_reload",
        description: "Reload Tachyon config without full restart.",
        inputSchema: { type: "object", properties: {} },
        annotations: { readOnlyHint: false }
    },
    {
        name: "tachyon_set_config",
        description: "Set a UCI configuration option (tachyon.<section>.<option> = <value>).",
        inputSchema: {
            type: "object",
            required: ["section", "option", "value"],
            properties: {
                section: { type: "string", description: "UCI section name" },
                option: { type: "string", description: "UCI option name" },
                value: { type: "string", description: "Value to set" }
            }
        },
        annotations: { readOnlyHint: false, destructiveHint: false }
    },
    {
        name: "tachyon_toggle_section",
        description: "Enable or disable a routing section.",
        inputSchema: {
            type: "object",
            required: ["section"],
            properties: {
                section: { type: "string", description: "Section .name" }
            }
        },
        annotations: { readOnlyHint: false }
    },
    {
        name: "tachyon_add_domain",
        description: "Add a domain to a routing section's domain list.",
        inputSchema: {
            type: "object",
            required: ["section", "domain"],
            properties: {
                section: { type: "string", description: "Section .name" },
                domain: { type: "string", description: "Domain to add (e.g. example.com or *.example.com)" }
            }
        },
        annotations: { readOnlyHint: false }
    },
    {
        name: "tachyon_ai_doctor",
        description: "Run AI-powered diagnostics. Returns root cause analysis with probability scores and quick fix codes.",
        inputSchema: { type: "object", properties: {} },
        annotations: { readOnlyHint: true }
    },
    {
        name: "tachyon_apply_fix",
        description: "Apply a quick fix code. Available codes: start_singbox, rebuild_rules, fix_dnsmasq, fix_resolv_symlink, start_watchdog, restart_singbox_dns, fix_uci_config, fix_wan_interface, fix_gateway, clear_dns_cache, update_subscriptions, reset_firewall, restart_network, restart_zapret, optimize_memory, switch_to_doh.",
        inputSchema: {
            type: "object",
            required: ["codes"],
            properties: {
                codes: {
                    type: "string",
                    description: "Comma-separated fix codes (e.g. 'start_singbox,clear_dns_cache')"
                }
            }
        },
        annotations: { readOnlyHint: false, destructiveHint: true }
    },
    {
        name: "tachyon_config_plan",
        description: "Dry-run plan & preflight validation for candidate configuration changes without applying them (detects port collisions, invalid syntax, DNS loops, affected subsystems, and diff).",
        inputSchema: {
            type: "object",
            properties: {
                candidate: { type: "object", description: "Candidate configuration object or section dictionary" },
                candidate_raw: { type: "string", description: "Candidate configuration as raw UCI text" }
            }
        },
        annotations: { readOnlyHint: true }
    },
    {
        name: "tachyon_known_good",
        description: "Inspect, promote, rollback, or check Last Known Good (LKG) configuration state and observation window.",
        inputSchema: {
            type: "object",
            properties: {
                action: { type: "string", enum: ["status", "promote", "rollback", "check"], description: "Action to perform (default: status)" },
                reason: { type: "string", description: "Reason for promotion or rollback" },
                force:  { type: "boolean", description: "Force rollback even if active config hash matches" }
            }
        }
    },
    {
        name: "tachyon_support_bundle",
        description: "Generate a sanitized diagnostic support bundle archive (.tar.gz) containing redacted logs, configurations, networking status, and system metrics.",
        inputSchema: {
            type: "object",
            properties: {
                target_path: { type: "string", description: "Target archive path on filesystem (optional, default: /tmp/tachyon-support-bundle-YYYYMMDD-HHMMSS.tar.gz)" },
                no_archive:  { type: "boolean", description: "Collect files without packaging into .tar.gz (optional)" }
            }
        },
        annotations: { readOnlyHint: false, destructiveHint: false }
    },
    {
        name: "tachyon_route_explain",
        description: "Explain why and how traffic from a LAN client to a target domain/IP is routed or bypassed across DNS, nftables (inet TachyonTable), policy routing (table tachyon), and tachyon-core / local providers.",
        inputSchema: {
            type: "object",
            required: ["target"],
            properties: {
                target: { type: "string", description: "Destination domain or IP (e.g. youtube.com, 1.1.1.1)" },
                client: { type: "string", description: "Optional LAN client IP or MAC address" },
                port:   { type: "integer", description: "Destination port (default: 443)" },
                proto:  { type: "string", enum: ["tcp", "udp"], description: "Transport protocol (default: tcp)" }
            }
        },
        annotations: { readOnlyHint: true, destructiveHint: false }
    },
    {
        name: "tachyon_docs_search",
        description: "Search the built-in Tachyon RAG knowledge base (22 technical manuals covering architecture, modular UCI schema, nftables, DNS, Zapret/Zapret2/ByeDPI, reconciler, transactions, jobs, events, troubleshooting) for relevant documentation chunks.",
        inputSchema: {
            type: "object",
            required: ["query"],
            properties: {
                query: { type: "string", description: "Search keywords (e.g. 'zapret2 multisplit', 'outbound_source balancer', 'bootstrap dns', 'reconciler')" },
                top_k: { type: "integer", description: "Max documentation chunks to return (1..15, default: 5)" }
            }
        },
        annotations: { readOnlyHint: true, destructiveHint: false }
    }
];

// ─── Resource Definitions ───────────────────────────────────────────────────

let RESOURCES = [
    {
        uri: "tachyon://knowledge/architecture",
        name: "Tachyon Architecture & Packet Pipeline",
        description: "Complete architectural overview: routing engines (tachyon-core & sing-box), DNS & FakeIP pipeline, nftables inet TachyonTable, modular UCI entities, local packet desync & tunnel providers, self-healing reconciler & transaction engine.",
        mimeType: "application/json"
    },
    {
        uri: "tachyon://knowledge/privacy-rules",
        name: "AI Privacy & Data Protection Rules",
        description: "Mandatory privacy and redaction rules for connected LLMs and MCP/REST agents interacting with Tachyon.",
        mimeType: "application/json"
    },
    {
        uri: "tachyon://knowledge/faq",
        name: "Tachyon FAQ",
        description: "Frequently asked questions and operational guide for Tachyon on OpenWrt.",
        mimeType: "application/json"
    },
    {
        uri: "tachyon://knowledge/config-schema",
        name: "Configuration Schema",
        description: "Complete modular UCI configuration schema for /etc/config/tachyon — settings, section, condition, outbound_source, balancer, outbound_group, server, telegram, guest_mode.",
        mimeType: "application/json"
    },
    {
        uri: "tachyon://knowledge/codebase-map",
        name: "Codebase Map",
        description: "Directory structure and ucode module map of the Tachyon project.",
        mimeType: "application/json"
    },
    {
        uri: "tachyon://knowledge/troubleshooting",
        name: "Troubleshooting Guide",
        description: "Common symptoms, root causes, and all 25 automated quick-fix codes.",
        mimeType: "application/json"
    },
    {
        uri: "tachyon://diagnostics/last",
        name: "Last AI Doctor Report",
        description: "The most recent AI Doctor diagnosis report with root causes and quick fixes (redacted).",
        mimeType: "application/json"
    },
    {
        uri: "tachyon://system/info",
        name: "System Info",
        description: "Current system information: versions, capabilities, uptime, memory.",
        mimeType: "application/json"
    }
];

// ─── Knowledge Base ─────────────────────────────────────────────────────────

let KNOWLEDGE_BASE = {
    "tachyon://knowledge/architecture": {
        tachyon_version: SERVER_VERSION,
        engines: {
            "tachyon-core": {
                uci_value: "tachyon-core",
                init_script: "/etc/init.d/tachyon-core",
                binary: "/usr/bin/tachyon-core",
                config_path: "/etc/tachyon-core/config.json",
                generator_dir: "usr/lib/tachyon/tachyon_core/"
            },
            "sing-box": {
                uci_value: "sing-box",
                init_script: "/etc/init.d/tachyon-core",
                binary: "/usr/bin/sing-box",
                config_path: "/etc/sing-box/config.json",
                variants: ["stable", "tiny", "extended (shtorm-7 with AmneziaWG)", "extended-compressed", "lx (Leadaxe/sing-box-lx)"],
                generator_dir: "usr/lib/tachyon/tachyon_core/"
            }
        },
        packet_and_dns_pipeline: {
            dns_interception: "LAN client -> dnsmasq -> forwards queries to tachyon-core DNS on 127.0.0.42:53 -> FakeIP pool 198.18.0.0/15 or nftset population",
            bootstrap_dns: "settings.bootstrap_dns_server (default 77.88.8.8 / 8.8.8.8) resolves proxy server hostnames directly to prevent circular DNS deadlocks",
            nftables_table: "inet TachyonTable (isolated from system inet fw4)",
            fwmarks: {
                "0x04000000": "NFT_FAKEIP_MARK — TProxy redirection mark routed via ip rule to routing table 'tachyon' (205)",
                "0x40000000": "NFT_COMMON_MARK — NFQueue bypass mark set by nfqws/nfqws2 after packet desynchronization to prevent re-queueing loops",
                "0x08000000": "Strategy Fuzzer isolated sandbox mark (queues 298/299)"
            },
            listening_ports: {
                tproxy: "1602 (TCP/UDP transparent proxy inbound)",
                core_dns: "127.0.0.42:53",
                clash_api: "127.0.0.1:9090",
                byedpi_socks: "127.0.0.1:4539 (fuzzer sandbox: 11089)"
            }
        },
        local_providers: {
            zapret: "Classic nfqws (v1) on NFQueue 200+. Uses --dpi-desync=fake,split2,disorder2 --dpi-desync-split-pos=... flags.",
            zapret2: "Modern nfqws2 (v2) on NFQueue 201+ with Lua engine (/opt/zapret2/lua/zapret-lib.lua, zapret-antidpi.lua, zapret-auto.lua). Uses --lua-desync=multisplit:pos=1,midsld:seqovl=1:fooling=badseq (and :payload=all for unknown UDP).",
            byedpi: "Local SOCKS5 packet desynchronizer ciadpi on port 4539.",
            wdtt: "WebRTC / Discord / Telegram tunnel provider (providers/wdtt/).",
            olcrtc: "OlcRTC media & voice relay provider (providers/olcrtc/).",
            fptn: "FPTN censorship-resistant VPN client provider (providers/fptn/).",
            tailscale: "Mesh VPN integration (providers/tailscale/) with native or sing-box endpoint modes.",
            torrserver: "Direct bypass helper for TorrServer local media traffic (torrserver/direct.uc)."
        },
        reliability_and_self_healing: {
            watchdog: "service/watchdog.uc — periodic health supervisor with WAN/Proxy/DNS fail streak hysteresis, OOM guard, and Smart Detect.",
            reconciler: "service/reconciler.uc — declarative desired-vs-actual state diffing and targeted subsystem repair (engine, daemons, routing, nftables, dns) without dropping active connections.",
            known_good: "service/known_good.uc — Last Known Good (/etc/tachyon/state/known_good/) observation window, promotion, and automatic rollback.",
            transaction: "core/transaction.uc — atomic 8-phase transaction engine (PLAN -> PREFLIGHT -> SNAPSHOT -> MUTATE -> VALIDATE -> ACTIVATE -> VERIFY -> COMMIT) with LIFO rollback.",
            jobs: "core/jobs.uc — background job engine with PID+starttime+boot_id identity, heartbeat, cooperative cancellation, and critical sections.",
            events: "core/events.uc — in-memory pub/sub bus and bounded ring journal (/var/run/tachyon/events.jsonl) with write-time secret redaction."
        }
    },

    "tachyon://knowledge/privacy-rules": {
        policy: "Strict Zero-Secret-Leakage Policy for Connected LLMs and External Agents",
        automatic_redaction: [
            "All UCI configs returned by tachyon_config / GET /config are masked via diagnostics/status.uc (tachyon-config-masked).",
            "All diffs returned by tachyon_config_plan / POST /config/plan redact old_value and new_value for sensitive options.",
            "All logs, snapshots, diagnostic reports, and RAG queries are scrubbed by service/support_bundle.uc and core/events.uc redaction pipelines.",
            "Redacted items include: Telegram bot tokens, chat IDs, Bearer tokens, LLM API keys (sk-*, AIza*, gsk_*, xai-*), proxy URIs (vless://, vmess://, trojan://, ss://, hysteria2://, fptn://, warp://), UUIDs, WireGuard/AWG/Reality keys, passwords, HWIDs, subscription URL tokens, and client MAC addresses."
        ],
        agent_instructions: [
            "NEVER ask the user to paste plaintext private keys, passwords, API keys, Telegram bot tokens, UUIDs, or full subscription URLs.",
            "NEVER attempt to read raw /etc/config/tachyon bypassing the masked config API.",
            "Always use tachyon_config_plan to validate candidate changes before applying them.",
            "When sharing diagnostics externally, use tachyon_support_bundle which produces a SHA-256 verified, fully redacted archive."
        ]
    },

    "tachyon://knowledge/faq": {
        tachyon_version: SERVER_VERSION,
        faq: [
            {
                q: "YouTube/Discord/Telegram не работает или тормозит",
                a: "Используйте `tachyon_route_explain` для проверки маршрута до домена (например, youtube.com или discord.com). Для локальной десинхронизации без VPS выберите провайдер `zapret2` (`--lua-desync=multisplit:pos=1,midsld:seqovl=1:fooling=badseq`) или запустите Strategy Fuzzer (`tachyon fuzzer_start zapret2 youtube_suite`). Для проксирования через VPS убедитесь, что секция активна и привязана к рабочему `outbound_source` / `balancer`.",
                steps: [
                    "Вызовите tachyon_route_explain с target='youtube.com'",
                    "Проверьте статус ядра и провайдеров через tachyon_snapshot и tachyon_diagnose",
                    "При необходимости обновите подписки (update_subscriptions) или перезапустите провайдеры (restart_zapret)"
                ]
            },
            {
                q: "Пропал интернет после включения Tachyon",
                a: "Tachyon перенаправляет DNS-запросы из dnsmasq в tachyon-core (127.0.0.42:53). Если ядро остановлено или недоступен bootstrap DNS, резолвинг останавливается. Для мгновенного восстановления интернета выполните quick fix `restore_native_internet` или `heal_network_stack`.",
                steps: [
                    "Вызовите tachyon_diagnose для точного выявления причины",
                    "Примените tachyon_apply_fix с кодом 'start_singbox,fix_dnsmasq' или 'heal_network_stack'",
                    "Для полного аварийного отключения перехвата: tachyon_apply_fix с кодом 'restore_native_internet'"
                ]
            },
            {
                q: "Как добавить домен в секцию маршрутизации?",
                a: "Используйте инструмент `tachyon_add_domain` (он автоматически найдёт привязанный атомарный `condition` секции и добавит домен в `user_domains`, после чего перезагрузит правила).",
                method: "POST /tachyon/agent/v1/domain/add"
            },
            {
                q: "Как безопасно проверить изменения конфигурации перед применением?",
                a: "Используйте `tachyon_config_plan` — он выполнит dry-run расчёт diff, проверит семантику UCI, коллизии портов, затенение правил (rule shadowing) и определит, нужен ли рестарт или достаточно мягкой перезагрузки.",
                cli: "tachyon config_plan --json"
            },
            {
                q: "Как найти подробную документацию по любой подсистеме Tachyon?",
                a: "Используйте инструмент `tachyon_docs_search` с ключевыми словами (например, 'zapret2', 'reconciler', 'outbound_group', 'fakeip', 'known_good'). Он ищет по всем 22 техническим руководствам встроенной базы знаний RAG."
            }
        ],
        tips: [
            "Always start with 'tachyon_snapshot' and 'tachyon_diagnose' to get the full picture.",
            "Use 'tachyon_route_explain' to trace exact DNS, nftables, and outbound decisions for any domain or IP.",
            "Use 'tachyon_docs_search' whenever you need deep technical details on UCI options, Zapret2 Lua flags, or internal modules.",
            "Use 'tachyon_config_plan' before mutating UCI configuration."
        ]
    },

    "tachyon://knowledge/config-schema": {
        config_file: "/etc/config/tachyon (chmod 0600)",
        architecture_note: "Tachyon uses a modular relational UCI schema: `section` references `condition` (via condition_refs), `outbound_source` (via outbound_source_refs), `balancer` (via balancer_refs), and `outbound_group` (via outbound_group_ref).",
        sections: {
            settings: {
                type: "settings",
                description: "Global Tachyon settings (`config settings 'settings'`)",
                options: {
                    engine: { type: "string", default: "tachyon-core", description: "Active routing engine: tachyon-core | sing-box" },
                    dns_type: { type: "string", default: "doh", description: "Upstream DNS protocol: doh | dot | udp" },
                    dns_server: { type: "string/list", default: "1.1.1.1", description: "Remote DNS resolver(s)" },
                    bootstrap_dns_server: { type: "string/list", default: "77.88.8.8", description: "Direct bootstrap DNS resolver(s) bypassing proxy" },
                    fallback_dns_server: { type: "string", description: "Fallback DNS resolver" },
                    source_network_interfaces: { type: "list", default: "br-lan", description: "LAN interfaces intercepted by Tachyon" },
                    enable_ipv6: { type: "bool", default: "0", description: "Enable IPv6 routing and nftables sets" },
                    enable_watchdog: { type: "bool", default: "1", description: "Enable autonomous watchdog supervisor" },
                    enable_smart_detect: { type: "bool", default: "0", description: "Automatically detect degraded domains and suggest routing" },
                    enable_ai_doctor: { type: "bool", default: "0", description: "Enable LLM AI Doctor integration" },
                    enable_rag: { type: "bool", default: "1", description: "Enable RAG knowledge base retrieval for AI Doctor" },
                    ai_doctor_provider: { type: "string", description: "openai | anthropic | gemini | deepseek | openrouter | groq | xai | mistral | ollama | lmstudio | custom" },
                    ai_doctor_model: { type: "string", description: "Custom LLM model name override" },
                    ai_doctor_api_key: { type: "string", description: "API key for LLM provider (REDACTED in outputs)" },
                    ai_doctor_custom_url: { type: "string", description: "Custom OpenAI-compatible endpoint URL" },
                    agent_api_token: { type: "string", description: "Bearer token enabling HTTP Agent API gateway and write operations" },
                    latency_test_url: { type: "string", default: "http://cp.cloudflare.com/generate_204", description: "URL used for proxy latency probes" },
                    recovery_bypass: { type: "bool", default: "0", description: "Emergency safe direct WAN bypass flag" }
                }
            },
            section: {
                type: "section",
                description: "Routing rule orchestrator (`config section '<name>'`)",
                options: {
                    enabled: { type: "bool", default: "1", description: "Enable or disable this routing section" },
                    label: { type: "string", description: "Human-readable display name" },
                    connection_type: { type: "string", description: "Target mode: proxy | vpn | direct | block | zapret | zapret2 | byedpi | wdtt | olcrtc | fptn | tailscale | multipath" },
                    action: { type: "string", description: "Normalized action: proxy | direct | block | zapret | zapret2 | byedpi | wdtt | olcrtc | fptn | tailscale" },
                    priority: { type: "int", default: "100", description: "Rule evaluation order priority (lower runs first)" },
                    condition_refs: { type: "list", description: "References to `condition` sections defining traffic matchers" },
                    outbound_source_refs: { type: "list", description: "References to `outbound_source` sections providing proxy nodes" },
                    balancer_refs: { type: "list", description: "References to `balancer` sections" },
                    outbound_group_ref: { type: "string", description: "Reference to `outbound_group` section for primary/backup failover" },
                    fail_policy: { type: "string", default: "direct", description: "Fallback behavior when all outbounds fail: direct | block |backup" }
                }
            },
            condition: {
                type: "condition",
                description: "Reusable traffic matching condition (`config condition '<name>'`)",
                options: {
                    enabled: { type: "bool", default: "1", description: "Enable condition" },
                    name: { type: "string", description: "Display label" },
                    condition_type: { type: "string", default: "atomic", description: "atomic | composite" },
                    community_lists: { type: "list", description: "Predefined community domain/subnet lists (e.g. youtube, discord, meta, telegram)" },
                    user_domains: { type: "list", description: "Custom domains and suffixes" },
                    user_domains_text: { type: "string", description: "Multiline custom domain list" },
                    user_subnets: { type: "list", description: "Custom IPv4/IPv6 CIDR subnets" },
                    remote_domain_lists: { type: "list", description: "External URLs for domain lists" },
                    remote_subnet_lists: { type: "list", description: "External URLs for subnet lists" },
                    geoip_codes: { type: "list", description: "GeoIP country codes" },
                    geosite_codes: { type: "list", description: "GeoSite category codes" },
                    dest_ports: { type: "list", description: "Destination TCP/UDP ports or ranges" },
                    l4_proto: { type: "string", description: "Protocol filter: tcp | udp | both" },
                    client_ips: { type: "list", description: "Source LAN client IP/CIDR filter" },
                    client_macs: { type: "list", description: "Source LAN client MAC filter" }
                }
            },
            outbound_source: {
                type: "outbound_source",
                description: "Proxy/tunnel node source (`config outbound_source '<name>'`)",
                options: {
                    enabled: { type: "bool", default: "1", description: "Enable source" },
                    name: { type: "string", description: "Display label" },
                    source_type: { type: "string", description: "subscription | url | links | json | amnezia | wireguard | provider" },
                    subscription_url: { type: "string", description: "Remote subscription URL (REDACTED)" },
                    subscription_urls: { type: "list", description: "Multiple subscription URLs (REDACTED)" },
                    proxy_links: { type: "list", description: "Direct proxy share links vless://, trojan://, hysteria2://, ss:// (REDACTED)" },
                    outbound_json: { type: "string", description: "Custom sing-box outbound JSON (REDACTED)" },
                    provider_kind: { type: "string", description: "Local provider: zapret | zapret2 | byedpi | wdtt | olcrtc | fptn | tailscale" },
                    nfqws2_strategy: { type: "string", description: "Zapret2 (--lua-desync=...) strategy arguments" },
                    nfqws_strategy: { type: "string", description: "Zapret v1 (--dpi-desync=...) strategy arguments" },
                    byedpi_strategy: { type: "string", description: "ByeDPI (ciadpi) strategy arguments" }
                }
            },
            balancer: {
                type: "balancer",
                description: "Load balancer and health probe policy (`config balancer '<name>'`)",
                options: {
                    enabled: { type: "bool", default: "1", description: "Enable balancer" },
                    balancer_type: { type: "string", default: "urltest", description: "urltest | selector | least_ping | round_robin" },
                    check_interval: { type: "string", default: "3m", description: "Health check interval" },
                    tolerance: { type: "int", default: "50", description: "Latency tolerance in ms" },
                    testing_url: { type: "string", description: "Probe URL for urltest" },
                    sticky_hash: { type: "string", description: "Sticky session hashing mode (for extended/lx cores)" },
                    passive_check: { type: "bool", description: "Enable passive health checking" }
                }
            },
            outbound_group: {
                type: "outbound_group",
                description: "High-availability failover group (`config outbound_group '<name>'`)",
                options: {
                    enabled: { type: "bool", default: "1", description: "Enable group" },
                    primary_balancer: { type: "string", description: "Primary balancer reference" },
                    backup_balancer: { type: "string", description: "Backup failover balancer reference" },
                    fail_policy: { type: "string", default: "direct", description: "Action if both primary and backup fail: direct | block" }
                }
            },
            server: {
                type: "server",
                description: "Inbound server node hosted on the router (`config server '<name>'`)",
                options: {
                    label: { type: "string", description: "Display name" },
                    enabled: { type: "bool", description: "Enable/disable this inbound server" },
                    protocol: { type: "string", description: "vless | vmess | trojan | shadowsocks | hysteria2 | tuic | wireguard | amneziawg | tailscale | mixed | socks | http | shadowtls | anytls | naive | mieru | snell | trusttunnel | tewfai | sudoku | openconnect | mtproto | json_inbound" },
                    listen: { type: "string", default: "0.0.0.0", description: "Listen IP address" },
                    listen_port: { type: "string", description: "Listen port" },
                    public_host: { type: "string", description: "Public hostname or IP for client share links" },
                    routing_mode: { type: "string", description: "rules | direct | section" },
                    routing_section: { type: "string", description: "Target section when routing_mode='section'" },
                    isolate_lan_for_users: { type: "bool", description: "Block LAN access for inbound clients" }
                }
            }
        }
    },

    "tachyon://knowledge/codebase-map": {
        description: "Tachyon codebase layout (ucode backend + TypeScript LuCI frontend)",
        structure: {
            "tachyon/files/": {
                "etc/config/tachyon": "Main UCI configuration file (chmod 600)",
                "etc/init.d/tachyon": "Main procd service init script",
                "usr/bin/tachyon": "Main CLI dispatcher (ucode)",
                "usr/lib/tachyon/": {
                    "core/": "Foundational modules: common.uc, constants.uc, engine.uc, events.uc (bus + ring journal + redaction), exec.uc, gomemlimit.uc, helpers.uc, ip.uc, jobs.uc (cancellable job engine), logging.uc, packages.uc, preflight.uc, process.uc (PID+starttime+boot_id), transaction.uc (atomic LIFO rollback), uci.uc, url.uc",
                    "config/": "Configuration model: connections.uc, domain.uc, migration.uc, rule.uc, validator.uc",
                    "diagnostics/": "Diagnostics & AI: runtime.uc, doctor.uc (Local & AI Doctor), repairs.uc (25 quick fixes), rag.uc (hybrid vector + lexical RAG), route_explain.uc (packet path tracer), fuzzer.uc & fuzzer/* (Strategy Fuzzer + AI generator), dns.uc, network.uc, routing.uc, status.uc, system_info.uc, leak_check.uc, stability.uc, server_stats.uc",
                    "service/": "Lifecycle & APIs: lifecycle.uc, initd.uc, reload.uc, reset.uc, state.uc, reconciler.uc (self-healing drift repair), known_good.uc (LKG rollback), config_plan.uc (dry-run preflight & diff), support_bundle.uc (sanitized archive & redaction), watchdog.uc, smart_detect.uc, failover.uc, agent_api.uc (HTTP REST API), agent_mcp.uc (MCP stdio server), snapshot.uc, telegram.uc & telegram/*",
                    "tachyon_core/": "tachyon-core / sing-box config compiler: generator.uc, generator_outbounds.uc, generator_routes.uc, dns.uc, dns_failover.uc, dns_presets.uc, priority.uc, route.uc, rulesets.uc, runtime.uc, servers.uc, subscription.uc, urltest.uc, variant_state.uc",
                    "providers/": "Packet desync & tunnel providers: zapret/ (nfqws), zapret2/ (nfqws2 + lua/), byedpi/ (ciadpi), nfqueue/, wdtt/, olcrtc/, fptn/, tailscale/, rules.uc, status.uc",
                    "nft/": "nftables compiler: apply.uc (table inet TachyonTable, sets, TProxy, NFQueue)",
                    "dns/": "DNS coordinator: apply.uc, benchmark.uc, speed_test.uc",
                    "components/": "Component manager: catalog.uc, action.uc, installer.uc, updater.uc, updates.uc, versions.uc, verifier.uc, engine_state.uc, hosts.uc",
                    "subscription/": "Subscription & link parsers: parser.uc, cache.uc, share_link.uc, wireguard.uc, amnezia.uc, happ.uc, crypt4.uc",
                    "server/": "Inbound server manager: service.uc, links.uc, subscription.uc",
                    "torrserver/": "TorrServer direct bypass: direct.uc",
                    "rag_index.json": "Compiled RAG documentation chunks from docs/knowledge-base/*.md"
                }
            },
            "fe-app-tachyon/": "TypeScript SPA source for LuCI UI",
            "luci-app-tachyon/": "Compiled LuCI JS views and i18n translations",
            "docs/knowledge-base/": "22 authoritative technical reference manuals indexed into rag_index.json",
            "tests/": "Standalone behavioral shell & ucode test suite"
        }
    },

    "tachyon://knowledge/troubleshooting": {
        quick_fix_codes: [
            "start_singbox — Restart tachyon-core / sing-box and restore dnsmasq wiring",
            "rebuild_rules — Reload Tachyon nftables and policy routing rules",
            "fix_dnsmasq — Restart dnsmasq daemon",
            "fix_resolv_symlink — Repair broken /etc/resolv.conf symlink to resolv.conf.auto",
            "start_watchdog — Restart Tachyon service and watchdog daemon",
            "restart_singbox_dns — Restart tachyon-core DNS subsystem",
            "fix_uci_config — Restore /etc/config/tachyon from atomic backup",
            "fix_wan_interface — Re-up WAN interface via ubus/ifup and flush route cache",
            "fix_gateway — Restart network service to recover default gateway",
            "clear_dns_cache — Flush DNS and route caches and restart dnsmasq",
            "update_subscriptions — Trigger asynchronous proxy subscription refresh",
            "reset_firewall — Restart OpenWrt fw4 firewall and reload Tachyon rules",
            "restart_network — Restart OpenWrt network stack",
            "restart_zapret — Stop conflicting standalone services and restart Tachyon zapret/zapret2/byedpi runtimes",
            "restart_providers — Restart WDTT, OlcRTC, and FPTN provider runtimes",
            "fix_system_time — Force NTP clock synchronization (fixes TLS handshake failures)",
            "flush_conntrack — Expand nf_conntrack_max to 65536 and flush conntrack table",
            "fix_bootstrap_dns — Reset bootstrap_dns_server to 77.88.8.8 and reload",
            "optimize_mtu — Run AWG MTU discovery and reload tunnels",
            "heal_network_stack — Full recovery of resolv.conf, dnsmasq, tachyon, and WAN",
            "enable_safe_bypass — Enable recovery_bypass='1' for direct WAN fallback",
            "restore_native_internet — Stop Tachyon, delete inet TachyonTable, flush table tachyon, restore stock dnsmasq",
            "optimize_memory — Drop kernel VM caches, clean tmp files, restart tachyon-core",
            "switch_to_doh — Switch settings.dns_type to 'doh' and reload",
            "upgrade_to_singbox_extended — Install sing-box-extended fork for AmneziaWG and advanced protocols"
        ],
        symptoms: [
            {
                symptom: "No internet after enabling Tachyon",
                causes: [
                    "tachyon-core / sing-box not running while dnsmasq forwards to 127.0.0.42:53",
                    "Circular bootstrap DNS dependency or broken /etc/resolv.conf symlink",
                    "Corrupted nftables inet TachyonTable or missing ip rule for table tachyon",
                    "WAN interface or default gateway down"
                ],
                diagnose: "tachyon_diagnose or tachyon_route_explain",
                fixes: ["start_singbox", "fix_resolv_symlink", "fix_bootstrap_dns", "rebuild_rules", "restore_native_internet"]
            },
            {
                symptom: "YouTube / Discord / UDP games degrading or timing out",
                causes: [
                    "Outdated packet desynchronization strategy for current transit network filters",
                    "Missing :payload=all in zapret2 fake lua-desync for custom UDP game ports",
                    "Dead proxy outbound in subscription"
                ],
                diagnose: "tachyon_route_explain (check matched section and provider)",
                fixes: ["restart_zapret", "update_subscriptions"]
            },
            {
                symptom: "WireGuard / AmneziaWG tunnel shows TX > 0 but RX = 0 (handshake timeout)",
                causes: [
                    "Standard sing-box binary used instead of sing-box-extended for AmneziaWG parameters",
                    "Suboptimal tunnel MTU or external UDP endpoint filtering"
                ],
                diagnose: "tachyon_diagnose (check WireGuard/AWG tunnel check)",
                fixes: ["upgrade_to_singbox_extended", "optimize_mtu"]
            },
            {
                symptom: "High memory usage / OOM kills on 128-256 MB routers",
                causes: [
                    "Excessive ruleset compilation or memory pressure in core engine",
                    "Conntrack table saturation"
                ],
                diagnose: "tachyon_snapshot (check memory_mb_avail)",
                fixes: ["optimize_memory", "flush_conntrack"]
            },
            {
                symptom: "TLS handshakes fail across all HTTPS sites after reboot",
                causes: [
                    "Router clock desynchronized (no RTC battery, NTP blocked before tunnel up)"
                ],
                diagnose: "tachyon_diagnose (check System clock / NTP)",
                fixes: ["fix_system_time"]
            }
        ]
    }
};

// ─── Tool Execution ─────────────────────────────────────────────────────────
// NOTE: ucode on older OpenWrt has NO function hoisting — callers must be
// defined AFTER the functions they call. execute_tool() dispatches to the
// execute_* functions defined above it.

function text_result(text) {
    return { content: [{ type: "text", text: text }] };
}

function json_result(obj) {
    return { content: [{ type: "text", text: sprintf("%J", obj) }] };
}

function error_result(text) {
    return { content: [{ type: "text", text: text }], isError: true };
}

function execute_health() {
    let ai_raw = read_file("/tmp/tachyon_ai_status.json") || "{}";
    let ai = parse_json_safe(ai_raw) || {};
    let sb_pid = trim(command_output("pidof tachyon-core sing-box"));
    let wd_pid = trim(read_file("/var/run/tachyon_watchdog.pid") || "");
    return json_result({
        status: ai.status || (sb_pid != "" ? "healthy" : "critical"),
        singbox: sb_pid != "" ? "running" : "stopped",
        watchdog: (wd_pid != "" && fs.stat("/proc/" + wd_pid) != null) ? "running" : "stopped",
        incidents: ai.incidents_resolved_total || 0,
        timestamp: time()
    });
}

function execute_snapshot() {
    let res = module_capture(["get-system-info"]);
    let sys_info = parse_json_safe(res.output);

    let sb_pid = trim(command_output("pidof tachyon-core sing-box"));
    let wd_pid = trim(read_file("/var/run/tachyon_watchdog.pid") || "");

    let mem_info = read_file("/proc/meminfo") || "";
    let mem_avail = 0;
    for (let line in split(mem_info, "\n")) {
        if (index(line, "MemAvailable:") == 0) {
            let f = split(trim(line), /[ \t]+/);
            if (length(f) >= 2) mem_avail = int(f[1]) / 1024;
            break;
        }
    }

    let uptime_raw = read_file("/proc/uptime") || "0";
    let up_sec = double(split(uptime_raw, " ")[0] || 0);

    let logs_raw = command_output("logread -l 50 2>/dev/null | grep -i tachyon | tail -30");
    let logs = [];
    for (let line in split(logs_raw, "\n")) {
        line = trim(as_string(line));
        if (line != "") push(logs, redact_text(line));
    }

    let c = uci.cursor();
    c.load(CONFIG_NAME);
    let sections = [];
    let section_objs = uci.section_objects(CONFIG_NAME, "section");
    for (let s in section_objs) {
        push(sections, {
            name: s[".name"],
            label: s.label || s[".name"],
            enabled: s.enabled != "0",
            action: s.action || "unknown",
            condition_refs: s.condition_refs || [],
            outbound_source_refs: s.outbound_source_refs || [],
            balancer_refs: s.balancer_refs || [],
            group_members: s.group_members || []
        });
    }
    let conditions = [];
    for (let c_obj in uci.section_objects(CONFIG_NAME, "condition")) {
        push(conditions, {
            name: c_obj[".name"],
            label: c_obj.name || c_obj.label || c_obj[".name"],
            enabled: c_obj.enabled != "0"
        });
    }
    let outbound_sources = [];
    for (let src_obj in uci.section_objects(CONFIG_NAME, "outbound_source")) {
        push(outbound_sources, {
            name: src_obj[".name"],
            label: src_obj.name || src_obj.label || src_obj[".name"],
            enabled: src_obj.enabled != "0",
            source_type: src_obj.source_type || "subscription"
        });
    }
    let balancers = [];
    for (let bal_obj in uci.section_objects(CONFIG_NAME, "balancer")) {
        push(balancers, {
            name: bal_obj[".name"],
            label: bal_obj.name || bal_obj.label || bal_obj[".name"],
            enabled: bal_obj.enabled != "0",
            balancer_type: bal_obj.balancer_type || "urltest"
        });
    }

    return json_result({
        system: sys_info || {},
        services: {
            singbox: sb_pid != "" ? "running" : "stopped",
            watchdog: (wd_pid != "" && fs.stat("/proc/" + wd_pid) != null) ? "running" : "stopped"
        },
        memory_mb_avail: mem_avail,
        uptime_sec: int(up_sec),
        sections: sections,
        conditions: conditions,
        outbound_sources: outbound_sources,
        balancers: balancers,
        logs_tail: logs
    });
}

function execute_diagnose() {
    let res = module_capture(["diagnose-json"]);
    if (res.status != 0) {
        return error_result("Diagnostics failed: " + res.output);
    }
    let data = parse_json_safe(res.output);
    if (data == null) {
        return error_result("Invalid JSON from diagnostics");
    }
    return json_result(data);
}

function execute_logs() {
    let raw = command_output("logread -l 100 2>/dev/null | grep -i tachyon");
    let lines = [];
    for (let line in split(raw, "\n")) {
        line = trim(as_string(line));
        if (line != "") push(lines, redact_text(line));
    }
    return json_result({ lines: lines });
}

function execute_config() {
    let res = module_capture(["show-config", "masked"]);
    let data = parse_json_safe(res.output);
    if (data != null) return json_result(data);
    return json_result({ raw: res.output });
}

function execute_heal() {
    let res = module_capture(["diagnose-json"]);
    let data = parse_json_safe(res.output);
    command_capture("ucode -L " + shell_quote(LIB_DIR) + " " + shell_quote(WATCHDOG_UC) + " ai-heal > /dev/null 2>&1");
    return json_result({
        message: "Self-healing completed",
        issues_found: data ? (data.issues_found || 0) : 0,
        issues_fixed: data ? (data.issues_fixed || 0) : 0,
        overall: data ? (data.overall || "unknown") : "unknown"
    });
}

function execute_restart(args) {
    let svc = as_string(args.service || "");
    let allowed = { singbox: 1, tachyon: 1, dnsmasq: 1, watchdog: 1 };
    if (!allowed[svc]) {
        return error_result("Unknown service '" + svc + "'. Allowed: singbox, tachyon, dnsmasq, watchdog");
    }
    let cmd_map = {
        singbox: "/etc/init.d/tachyon-core restart > /dev/null 2>&1",
        tachyon: "/etc/init.d/tachyon restart > /dev/null 2>&1",
        dnsmasq: "/etc/init.d/dnsmasq restart > /dev/null 2>&1",
        watchdog: "/usr/bin/tachyon watchdog start-runtime > /dev/null 2>&1"
    };
    system(cmd_map[svc]);
    return json_result({ message: "Restart of '" + svc + "' initiated" });
}

function execute_reload() {
    system("/usr/bin/tachyon reload > /dev/null 2>&1");
    return json_result({ message: "Reload initiated" });
}

function execute_set_config(args) {
    let section = as_string(args.section || "");
    let option = as_string(args.option || "");
    let value = as_string(args.value || "");
    if (section == "" || option == "") {
        return error_result("section and option are required");
    }
    let path = CONFIG_NAME + "." + section + "." + option;
    if (!uci.set(path, value)) {
        return error_result("Failed to set UCI option: " + path);
    }
    if (!uci.commit(CONFIG_NAME)) {
        return error_result("Failed to commit UCI config");
    }
    let sb = sb_mod();
    let display_val = (sb && sb.is_sensitive_key && sb.is_sensitive_key(option)) ? "[REDACTED]" : redact_text(value);
    return json_result({ message: "Set " + path + " = " + display_val });
}

function execute_toggle_section(args) {
    let section = as_string(args.section || "");
    if (section == "") return error_result("section is required");

    let s = uci.get_all(CONFIG_NAME, section);
    if (!s) return error_result("Section not found: " + section);

    let new_val = (s.enabled == "1") ? "0" : "1";
    if (!uci.set(CONFIG_NAME + "." + section + ".enabled", new_val)) {
        return error_result("Failed to toggle section");
    }
    uci.commit(CONFIG_NAME);
    system("/usr/bin/tachyon reload > /dev/null 2>&1");
    return json_result({
        message: "Section '" + section + "' is now " + (new_val == "1" ? "enabled" : "disabled"),
        enabled: new_val == "1"
    });
}

function execute_add_domain(args) {
    let section = as_string(args.section || "");
    let domain = as_string(args.domain || "");
    if (section == "" || domain == "") return error_result("section and domain are required");

    if (!match(domain, /^[a-zA-Z0-9*._-]+$/)) {
        return error_result("Invalid domain: " + domain);
    }

    let target_sec = section;
    let sec_obj = uci.get_all(CONFIG_NAME, section);
    if (type(sec_obj) == "object" && sec_obj[".type"] == "section") {
        let crefs = type(sec_obj.condition_refs) == "array" ? sec_obj.condition_refs : (sec_obj.condition_refs ? split(trim(as_string(sec_obj.condition_refs)), /[ \t,]+/) : []);
        for (let cid in crefs) {
            let cond_obj = uci.get_all(CONFIG_NAME, cid);
            if (type(cond_obj) == "object" && cond_obj.enabled != "0" && lc(as_string(cond_obj.condition_type || "atomic")) != "composite") {
                target_sec = cid;
                break;
            }
        }
    }

    let path = CONFIG_NAME + "." + target_sec + ".user_domains";
    if (!uci.add_list(path, domain)) {
        return error_result("Failed to add domain (section may not exist or domain already present)");
    }
    uci.commit(CONFIG_NAME);
    system("/usr/bin/tachyon reload > /dev/null 2>&1");
    return json_result({ message: "Domain '" + domain + "' added to '" + target_sec + "'" });
}

function execute_ai_doctor() {
    let res = command_capture("/usr/bin/tachyon ai_doctor 2>/dev/null");
    let data = parse_json_safe(res.output);
    if (data) return json_result(redact_obj(data));
    return text_result(redact_text(res.output || "AI Doctor returned no output"));
}

function execute_apply_fix(args) {
    let codes = as_string(args.codes || "");
    if (codes == "") return error_result("codes is required");
    let res = command_capture("/usr/bin/tachyon apply_quick_fix " + shell_quote(codes));
    let data = parse_json_safe(res.output);
    if (data) return json_result(data);
    return json_result({ message: "Fix command executed", codes: codes });
}

function execute_config_plan(args) {
    let candidate = args.candidate || args.candidate_raw || null;
    let config_plan_mod = require("service.config_plan");
    let res = config_plan_mod.plan(candidate);
    return json_result(res);
}

function execute_known_good(args) {
    args = args || {};
    let kg_mod = require("service.known_good");
    let action = args.action || "status";
    if (action == "promote") {
        return json_result(kg_mod.promote(args.reason || "mcp_promote", args.metrics || {}));
    }
    if (action == "rollback" || action == "restore") {
        return json_result(kg_mod.rollback_to_known_good(args.reason || "mcp_rollback", { force: args.force == true }));
    }
    if (action == "check") {
        return json_result(kg_mod.check_observation());
    }
    return json_result(kg_mod.get_status());
}

function execute_support_bundle(args) {
    args = args || {};
    let sb = sb_mod();
    if (!sb) return error_result("Failed to load support_bundle module");
    let target = as_string(args.target_path || args.path || "");
    if (target == "") target = null;
    let opts = {
        no_archive: args.no_archive == true
    };
    let res = sb.create_bundle(target, opts);
    if (!res.ok) {
        return error_result(res.error || "Failed to create support bundle");
    }
    return json_result(res);
}

function execute_route_explain(args) {
    args = args || {};
    let client = as_string(args.client || "");
    let target = as_string(args.target || "");
    let port = int(args.port || 0);
    let proto = as_string(args.proto || "tcp");
    if (target == "") {
        return error_result("target is required (e.g. domain or IP)");
    }
    let route_explain_mod = require("diagnostics.route_explain");
    let report = route_explain_mod.explain_route(client, target, port, proto);
    return json_result(report);
}

function execute_docs_search(args) {
    args = args || {};
    let q = trim(as_string(args.query || args.q || ""));
    let top_k = int(args.top_k || 5);
    if (q == "") {
        return error_result("query is required");
    }
    let rag_mod = require("diagnostics.rag");
    let results = rag_mod.search_docs ? rag_mod.search_docs(q, top_k) : [];
    return json_result({
        query: rag_mod.sanitize_query ? rag_mod.sanitize_query(q) : redact_text(q),
        count: length(results),
        results: results
    });
}

function execute_tool(name, args) {
    try {
        switch (name) {
        case "tachyon_health":
            return execute_health();
        case "tachyon_snapshot":
            return execute_snapshot();
        case "tachyon_diagnose":
            return execute_diagnose();
        case "tachyon_logs":
            return execute_logs();
        case "tachyon_config":
            return execute_config();
        case "tachyon_heal":
            return execute_heal();
        case "tachyon_restart":
            return execute_restart(args);
        case "tachyon_reload":
            return execute_reload();
        case "tachyon_set_config":
            return execute_set_config(args);
        case "tachyon_toggle_section":
            return execute_toggle_section(args);
        case "tachyon_add_domain":
            return execute_add_domain(args);
        case "tachyon_ai_doctor":
            return execute_ai_doctor();
        case "tachyon_apply_fix":
            return execute_apply_fix(args);
        case "tachyon_config_plan":
            return execute_config_plan(args);
        case "tachyon_known_good":
            return execute_known_good(args);
        case "tachyon_support_bundle":
            return execute_support_bundle(args);
        case "tachyon_route_explain":
            return execute_route_explain(args);
        case "tachyon_docs_search":
            return execute_docs_search(args);
        default:
            return { content: [{ type: "text", text: "Unknown tool: " + name }], isError: true };
        }
    } catch (e) {
        return { content: [{ type: "text", text: "Tool '" + name + "' error: " + as_string(e) }], isError: true };
    }
}

// ─── Resource Reading ───────────────────────────────────────────────────────

function read_resource(uri) {
    if (uri == "tachyon://diagnostics/last") {
        let raw = read_file("/tmp/ai_doctor_last.json");
        if (raw == "") return error_result("No previous AI Doctor report found");
        let data = parse_json_safe(raw);
        if (data == null) return error_result("Corrupted AI Doctor history file");
        return json_result(redact_obj(data));
    }

    if (uri == "tachyon://system/info") {
        let res = module_capture(["get-system-info"]);
        let data = parse_json_safe(res.output);
        if (data) return json_result(data);
        return error_result("Failed to get system info");
    }

    let resource = KNOWLEDGE_BASE[uri];
    if (resource) return json_result(resource);

    return error_result("Unknown resource: " + uri);
}

// ─── JSON-RPC Dispatcher ────────────────────────────────────────────────────

function handle_message(msg) {
    if (msg == null) return;

    let id = msg.id;
    let method = as_string(msg.method || "");
    let params = type(msg.params) == "object" ? msg.params : {};

    // Notifications (no id) — acknowledged silently
    if (id == null) {
        return;
    }

    if (method == "initialize") {
        write_rpc_response(id, {
            protocolVersion: MCP_PROTOCOL_VERSION,
            capabilities: {
                tools: { listChanged: false },
                resources: { subscribe: false, listChanged: false },
                logging: {}
            },
            serverInfo: {
                name: SERVER_NAME,
                version: SERVER_VERSION
            }
        });
        return;
    }

    if (method == "notifications/initialized") {
        // Client acknowledged — no response needed
        return;
    }

    if (method == "tools/list") {
        write_rpc_response(id, { tools: TOOLS });
        return;
    }

    if (method == "tools/call") {
        let tool_name = as_string(params.name || "");
        let tool_args = type(params.arguments) == "object" ? params.arguments : {};
        try {
            let result = execute_tool(tool_name, tool_args);
            write_rpc_response(id, result);
        } catch (e) {
            write_rpc_response(id, {
                content: [{ type: "text", text: "Tool execution error: " + as_string(e) }],
                isError: true
            });
        }
        return;
    }

    if (method == "resources/list") {
        write_rpc_response(id, { resources: RESOURCES });
        return;
    }

    if (method == "resources/read") {
        let uri = as_string(params.uri || "");
        try {
            let result = read_resource(uri);
            write_rpc_response(id, result);
        } catch (e) {
            write_rpc_error(id, -32603, "Resource read error: " + as_string(e));
        }
        return;
    }

    if (method == "ping") {
        write_rpc_response(id, {});
        return;
    }

    if (method == "logging/setLevel") {
        write_rpc_response(id, {});
        return;
    }

    write_rpc_error(id, -32601, "Method not found: " + method);
}

// ─── Main Loop ──────────────────────────────────────────────────────────────
// MCP stdio transport: read newline-delimited JSON-RPC messages from stdin.
// Two modes:
//   1. Pipe mode (non-tty): read all stdin, split by newline, process each
//   2. Interactive mode (tty): read line by line

function process_line(line) {
    line = trim(as_string(line));
    if (line == "") return;
    let msg = parse_json_safe(line);
    if (msg != null) {
        handle_message(msg);
    } else {
        let fallback_id = null;
        try { fallback_id = json(line).id; } catch(e) {}
        write_rpc_error(fallback_id, -32700, "Parse error");
    }
}

function main() {
    let stdin = fs.open("/dev/stdin", "r");
    if (!stdin) return;

    let tty_check = fs.popen("test -t 0", "r");
    let is_tty = tty_check ? (tty_check.close() == 0) : false;

    if (!is_tty) {
        // Pipe mode: read all, split by newline
        let data = stdin.read("all");
        stdin.close();
        if (data == null) return;
        for (let line in split(as_string(data), "\n"))
            process_line(line);
    } else {
        // Interactive mode: line by line
        while (true) {
            let line = stdin.read("line");
            if (line == null) break;
            process_line(as_string(line));
        }
        stdin.close();
    }
}

main();
