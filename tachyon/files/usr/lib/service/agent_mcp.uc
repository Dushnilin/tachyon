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

function write_json(obj) {
    print(sprintf("%J\n", obj));
}

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
    let status = pipe.close();
    status = int(status);
    if (status == -1) status = 255;
    let sig = status & 127;
    if (sig != 0) status = 128 + sig;
    else status = (status >> 8) & 255;
    return { status: status, output: data == null ? "" : as_string(data) };
}

function command_output(command) {
    let res = command_capture(command);
    return (res.status == 0) ? trim(res.output) : "";
}

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

function read_json_file(path) {
    let data = read_file(path);
    if (data == "") return null;
    return parse_json_safe(data);
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
    }
];

// ─── Resource Definitions ───────────────────────────────────────────────────

let RESOURCES = [
    {
        uri: "tachyon://knowledge/faq",
        name: "Tachyon FAQ",
        description: "Frequently asked questions and troubleshooting guide for Tachyon proxy service on OpenWrt.",
        mimeType: "application/json"
    },
    {
        uri: "tachyon://knowledge/config-schema",
        name: "Configuration Schema",
        description: "UCI configuration schema for /etc/config/tachyon — all sections, options, and their meanings.",
        mimeType: "application/json"
    },
    {
        uri: "tachyon://knowledge/codebase-map",
        name: "Codebase Map",
        description: "Directory structure and module map of the Tachyon project for understanding the codebase.",
        mimeType: "application/json"
    },
    {
        uri: "tachyon://knowledge/troubleshooting",
        name: "Troubleshooting Guide",
        description: "Common symptoms, their root causes, and step-by-step fix procedures.",
        mimeType: "application/json"
    },
    {
        uri: "tachyon://diagnostics/last",
        name: "Last AI Doctor Report",
        description: "The most recent AI Doctor diagnosis report with root causes and quick fixes.",
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
    "tachyon://knowledge/faq": {
        tachyon_version: SERVER_VERSION,
        faq: [
            {
                q: "YouTube/Discord/Telegram не работает",
                a: "Проверьте тип подключения в настройках. Для YouTube рекомендуется 'Прокси для YouTube'. Для Telegram — 'Прокси для Telegram'. Для остальных сайтов — 'Общий прокси'.",
                steps: ["Убедитесь что sing-box запущен", "Проверьте тип подключения", "Обновите подписку"]
            },
            {
                q: "Internet stopped working after enabling Tachyon",
                a: "Tachyon перехватывает DNS-запросы. Если sing-box не запущен, DNS не резолвится. Запустите sing-box или отключите Tachyon.",
                steps: ["Запустите sing-box через LuCI", "Проверьте DNS через 'nslookup google.com 127.0.0.42'", "Если DNS не работает, перезапустите dnsmasq"]
            },
            {
                q: "How to add a custom domain to proxy",
                a: "В LuCI → Tachyon → Servers выберите секцию, добавьте домен в список. Или через API: tachyon_add_domain.",
                method: "POST /tachyon/agent/v1/domain/add"
            },
            {
                q: "How to check if proxy is working",
                a: "Используйте команду 'tachyon check_proxy' или проверьте через LuCI → Tachyon → Diagnostic.",
                cli: "tachyon check_proxy"
            },
            {
                q: "sing-box config is invalid",
                a: "Конфиг пересоздаётся автоматически. Если не помогло, перезапустите: tachyon restart.",
                steps: ["tachyon restart", "Проверьте логи: logread | grep sing-box"]
            }
        ],
        tips: [
            "Always start with 'tachyon snapshot' to get the full picture.",
            "Use 'tachyon diagnose' for structured problem list.",
            "For memory-constrained routers, enable GOMEMLIMIT scaling.",
            "Community lists are downloaded to /tmp/sing-box/rulesets/."
        ]
    },

    "tachyon://knowledge/config-schema": {
        config_file: "/etc/config/tachyon",
        sections: {
            settings: {
                type: "settings",
                description: "Global Tachyon settings",
                options: {
                    core: { type: "string", default: "sing-box", description: "Core proxy engine: sing-box" },
                    routing_mode: { type: "string", default: "nftables", description: "Routing mode: nftables | tun2socks" },
                    dns_type: { type: "string", default: "doh", description: "DNS type: doh | udp | tcp" },
                    dns_server: { type: "list", description: "Main DNS server(s) as upstream" },
                    bootstrap_dns_server: { type: "list", description: "Bootstrap DNS server(s)" },
                    subscription_url: { type: "string", description: "Proxy subscription URL" },
                    enable_watchdog: { type: "bool", default: "1", description: "Enable watchdog daemon" },
                    enable_ai_doctor: { type: "bool", default: "0", description: "Enable AI Doctor LLM integration" },
                    ai_doctor_provider: { type: "string", description: "LLM provider: openai | anthropic | deepseek | ollama | lmstudio | custom" },
                    ai_doctor_api_key: { type: "string", description: "API key for LLM provider" },
                    source_network_interfaces: { type: "string", default: "br-lan", description: "LAN interfaces for DNS redirection" },
                    latency_test_url: { type: "string", description: "URL for latency testing" }
                }
            },
            section: {
                type: "section",
                description: "Routing/proxy section (each = one rule)",
                options: {
                    label: { type: "string", description: "Display name" },
                    enabled: { type: "bool", description: "Enable/disable this section" },
                    action: { type: "string", description: "Routing action: proxy | direct | block" },
                    domain: { type: "list", description: "Domains to route through this section" },
                    domain_list: { type: "list", description: "Community domain lists" },
                    community_lists: { type: "list", description: "Community list names to download" },
                    subscription_url: { type: "string", description: "Per-section subscription URL" }
                }
            },
            server: {
                type: "server",
                description: "Inbound server configuration (VLESS, VMess, Trojan, etc.)",
                options: {
                    label: { type: "string", description: "Display name" },
                    enabled: { type: "bool", description: "Enable/disable this server" },
                    protocol: { type: "string", description: "Protocol: vless | vmess | trojan | shadowsocks | hysteria2 | tuic | wireguard | tailscale | json_inbound" },
                    listen: { type: "string", default: "0.0.0.0", description: "Listen address" },
                    listen_port: { type: "string", description: "Listen port" },
                    public_host: { type: "string", description: "Public hostname for this server" },
                    routing_mode: { type: "string", description: "Per-server routing mode" },
                    security: { type: "string", description: "Security: tls reality none" }
                }
            }
        }
    },

    "tachyon://knowledge/codebase-map": {
        description: "Tachyon project structure",
        structure: {
            "tachyon/files/": {
                "etc/init.d/tachyon": "OpenWrt init script (procd service)",
                "usr/bin/tachyon": "CLI entry point (ucode dispatcher)",
                "usr/lib/tachyon/": {
                    "core/": "Core utilities: common, helpers, constants, events, ip, packages, uci, url",
                    "config/": "Config management: domain, rule, connections, migration, validator",
                    "diagnostics/": "Diagnostics engine: runtime, status, service_check",
                    "service/": "Service layer: agent_api, agent_mcp, lifecycle, state, ui, watchdog, telegram, warp_generator",
                    "singbox/": "sing-box integration: runtime, generator, dns, rulesets, subscription, urltest, country",
                    "server/": "Server inbound management: service",
                    "components/": "Component management: updates, updater, hosts, action",
                    "providers/": "External providers: zapret, zapret2, byedpi, nfqueue",
                    "nft/": "nftables rule generation: apply",
                    "routing/": "Routing rulesets",
                    "dns/": "DNS configuration: apply",
                    "subscription/": "Subscription parsing: parser, cache, share_link"
                }
            },
            "luci-app-tachyon/": "LuCI web UI package",
            "fe-app-tachyon/": "TypeScript source → builds into LuCI JS",
            "tests/": "Shell-based test suite"
        }
    },

    "tachyon://knowledge/troubleshooting": {
        symptoms: [
            {
                symptom: "No internet after enabling Tachyon",
                causes: [
                    "sing-box not running",
                    "DNS hijack without working upstream",
                    "nftables rules missing",
                    "WAN interface down"
                ],
                diagnose: "tachyon diagnose",
                fixes: ["start_singbox", "rebuild_rules", "clear_dns_cache", "fix_wan_interface"]
            },
            {
                symptom: "YouTube blocked / not loading",
                causes: [
                    "Wrong routing action (should be 'proxy')",
                    "Subscription node offline",
                    "ISP deep packet inspection blocking"
                ],
                diagnose: "tachyon check_proxy",
                fixes: ["update_subscriptions", "restart_zapret"]
            },
            {
                symptom: "Telegram not connecting",
                causes: [
                    "Telegram proxy not enabled",
                    "sing-box process crashed",
                    "MTProto proxy misconfigured"
                ],
                diagnose: "tachyon check_sing_box",
                fixes: ["start_singbox", "rebuild_rules"]
            },
            {
                symptom: "High memory usage / OOM kills",
                causes: [
                    "sing-box using too much memory",
                    "Too many routing rules",
                    "GOMEMLIMIT too high for device"
                ],
                diagnose: "tachyon diagnose (look for RAM check)",
                fixes: ["optimize_memory"]
            },
            {
                symptom: "DNS resolution fails",
                causes: [
                    "Bootstrap DNS unreachable",
                    "ISP blocking DNS",
                    "dnsmasq not pointing to sing-box"
                ],
                diagnose: "tachyon check_dns_available",
                fixes: ["clear_dns_cache", "switch_to_doh", "fix_dnsmasq"]
            },
            {
                symptom: "sing-box crash loop",
                causes: [
                    "Invalid generated config",
                    "Port conflict (4534 or 9090)",
                    "Missing sing-box binary"
                ],
                diagnose: "tachyon check_sing_box",
                fixes: ["start_singbox"]
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
    let sb_pid = trim(command_output("pidof sing-box"));
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

    let sb_pid = trim(command_output("pidof sing-box"));
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
        if (line != "") push(logs, line);
    }

    let c = uci.cursor();
    c.load(CONFIG_NAME);
    let sections = [];
    let section_objs = uci.section_objects(CONFIG_NAME, "section");
    for (let s in section_objs) {
        push(sections, {
            name: s[".name"],
            label: s.label || s[".name"],
            enabled: s.enabled == "1",
            action: s.action || "unknown"
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
        if (line != "") push(lines, line);
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
        singbox: "/etc/init.d/sing-box restart > /dev/null 2>&1",
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
    return json_result({ message: "Set " + path + " = " + value });
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

    let path = CONFIG_NAME + "." + section + ".domain";
    if (!uci.add_list(path, domain)) {
        return error_result("Failed to add domain (section may not exist or domain already present)");
    }
    uci.commit(CONFIG_NAME);
    system("/usr/bin/tachyon reload > /dev/null 2>&1");
    return json_result({ message: "Domain '" + domain + "' added to section '" + section + "'" });
}

function execute_ai_doctor() {
    let res = command_capture("/usr/bin/tachyon ai_doctor 2>/dev/null");
    let data = parse_json_safe(res.output);
    if (data) return json_result(data);
    return text_result(res.output || "AI Doctor returned no output");
}

function execute_apply_fix(args) {
    let codes = as_string(args.codes || "");
    if (codes == "") return error_result("codes is required");
    let res = command_capture("/usr/bin/tachyon apply_quick_fix " + shell_quote(codes));
    let data = parse_json_safe(res.output);
    if (data) return json_result(data);
    return json_result({ message: "Fix command executed", codes: codes });
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
        return json_result(data);
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
