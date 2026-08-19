#!/usr/bin/env ucode

// ─── Tachyon AI Agent API ─────────────────────────────────────────────────────
//
// HTTP handler for /tachyon/agent/v1/*
// Provides structured read/write endpoints for LLM agents (Claude, GPT, etc.)
//
// READ endpoints (no auth required from LAN):
//   GET  /tachyon/agent/v1/snapshot
//   GET  /tachyon/agent/v1/health
//   GET  /tachyon/agent/v1/diagnose
//   GET  /tachyon/agent/v1/logs
//   GET  /tachyon/agent/v1/config
//   GET  /tachyon/agent/v1/tools
//
// WRITE endpoints (require Bearer token via agent_api_token UCI option):
//   POST /tachyon/agent/v1/heal
//   POST /tachyon/agent/v1/restart
//   POST /tachyon/agent/v1/reload
//   POST /tachyon/agent/v1/config/set
//   POST /tachyon/agent/v1/section/toggle
//   POST /tachyon/agent/v1/domain/add

let fs = require("fs");
let uci = require("core.uci");
let common = require("core.common");

const CONFIG_NAME  = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const LIB_DIR      = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const RUNTIME_UC   = LIB_DIR + "/diagnostics/runtime.uc";
const WATCHDOG_UC  = LIB_DIR + "/service/watchdog.uc";
const API_VERSION  = "1";

let as_string = common.as_string;
let shell_quote = common.shell_quote;

let write_json = common.write_json;

let command_output = common.command_output;

function ok(data) {
    let result = { success: true };
    for (let k in keys(data)) result[k] = data[k];
    write_json(result);
}

function err(message, code) {
    write_json({ success: false, error: as_string(message), code: code || 400 });
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

function module_capture(args) {
    let parts = ["ucode", "-L", shell_quote(LIB_DIR), shell_quote(RUNTIME_UC)];
    for (let a in args) push(parts, shell_quote(as_string(a)));
    return command_capture(join(" ", parts));
}

function parse_json_safe(raw) {
    try { return json(as_string(raw)); } catch(e) { return null; }
}

function get_agent_token() {
    let c = uci.cursor();
    if (!c) return "";
    c.load(CONFIG_NAME);
    return as_string(c.get(CONFIG_NAME + ".settings.agent_api_token") || "");
}

function check_write_auth(bearer) {
    let token = get_agent_token();
    if (token == "") return false;
    return ("Bearer " + token) == as_string(bearer);
}

// ─── READ endpoints ───────────────────────────────────────────────────────────

function handle_health() {
    let ai_raw = fs.readfile("/tmp/tachyon_ai_status.json") || "{}";
    let ai = parse_json_safe(ai_raw) || {};
    let sb_pid = trim(command_output("pidof sing-box"));
    let wd_pid = trim(fs.readfile("/var/run/tachyon_watchdog.pid") || "");
    ok({
        status:    ai.status || (sb_pid != "" ? "healthy" : "critical"),
        singbox:   sb_pid != "" ? "running" : "stopped",
        watchdog:  (wd_pid != "" && fs.stat("/proc/" + wd_pid) != null) ? "running" : "stopped",
        incidents: ai.incidents_resolved_total || 0,
        timestamp: time()
    });
}

function handle_diagnose() {
    let res = module_capture(["diagnose-json"]);
    if (res.status != 0) {
        err("Diagnostics failed: " + res.output, 500);
        return;
    }
    let data = parse_json_safe(res.output);
    if (data == null) {
        err("Invalid JSON from diagnostics", 500);
        return;
    }
    print(res.output);
}

function handle_logs() {
    let raw = command_output("logread -l 100 2>/dev/null | grep -i tachyon");
    let lines = [];
    for (let line in split(raw, "\n")) {
        line = trim(as_string(line));
        if (line != "") push(lines, line);
    }
    ok({ lines: lines });
}

function handle_config() {
    let res = module_capture(["show-config", "masked"]);
    let data = parse_json_safe(res.output);
    if (data != null) {
        print(res.output);
    } else {
        ok({ raw: res.output });
    }
}

function handle_snapshot() {
    let mem_info = fs.readfile("/proc/meminfo") || "";
    let mem_avail = 0;
    for (let line in split(mem_info, "\n")) {
        if (index(line, "MemAvailable:") == 0) {
            let f = split(trim(line), /[ \t]+/);
            if (length(f) >= 2) mem_avail = int(f[1]) / 1024;
            break;
        }
    }

    let uptime_raw = fs.readfile("/proc/uptime") || "0";
    let up_sec = double(split(uptime_raw, " ")[0] || 0);
    let d = int(up_sec / 86400);
    let h = int((up_sec - d * 86400) / 3600);
    let m = int((up_sec - d * 86400 - h * 3600) / 60);

    let openwrt_ver = trim(command_output("cat /etc/openwrt_release 2>/dev/null | grep DISTRIB_RELEASE | cut -d= -f2 | tr -d '\"'"));
    let tachyon_ver = trim(command_output("opkg status tachyon 2>/dev/null | grep Version | awk '{print $2}'"));
    if (tachyon_ver == "")
        tachyon_ver = trim(command_output("apk list tachyon 2>/dev/null | head -1"));

    let sb_pid = trim(command_output("pidof sing-box"));
    let wd_pid = trim(fs.readfile("/var/run/tachyon_watchdog.pid") || "");
    let wd_ok = wd_pid != "" && fs.stat("/proc/" + wd_pid) != null;

    let proxy_resp = command_capture("curl -s -o /dev/null -m 5 --connect-timeout 3 -w '%{http_code}' --proxy http://127.0.0.1:4534 http://www.google.com 2>/dev/null").output;
    let direct_resp = command_capture("curl -s -o /dev/null -m 5 --connect-timeout 3 -w '%{http_code}' http://www.google.com 2>/dev/null").output;

    let ai_status = parse_json_safe(fs.readfile("/tmp/tachyon_ai_status.json") || "{}") || {};

    let logs_raw = command_output("logread -l 50 2>/dev/null | grep -i tachyon | tail -30");
    let logs = [];
    for (let line in split(logs_raw, "\n")) {
        line = trim(as_string(line));
        if (line != "") push(logs, line);
    }

    let sections = [];
    let section_objs = uci.section_objects(CONFIG_NAME, "section");
    for (let s in section_objs) {
        push(sections, {
            name:    s[".name"],
            label:   s.label || s[".name"],
            enabled: s.enabled == "1",
            action:  s.action || "unknown"
        });
    }

    ok({
        system: {
            openwrt_version: openwrt_ver || "unknown",
            tachyon_version: tachyon_ver || "unknown",
            uptime:          sprintf("%dd %02d:%02d", d, h, m),
            memory_mb_avail: mem_avail,
            timestamp:       time()
        },
        services: {
            singbox:  sb_pid != "" ? "running" : "stopped",
            watchdog: wd_ok ? "running" : "stopped"
        },
        connectivity: {
            direct_ok: int(direct_resp || "0") >= 200 && int(direct_resp || "0") < 400,
            proxy_ok:  int(proxy_resp  || "0") >= 200 && int(proxy_resp  || "0") < 400
        },
        incidents: {
            total: ai_status.incidents_resolved_total || 0,
            last:  ai_status.last_incident || null
        },
        sections:  sections,
        logs_tail: logs,
        agent_api: {
            version:              API_VERSION,
            tools_url:            "/tachyon/agent/v1/tools",
            write_auth_required:  get_agent_token() != ""
        }
    });
}

function handle_tools() {
    ok({
        schema_version: "1.0",
        description:    "Tachyon AI Agent API — diagnose and manage Tachyon on OpenWrt",
        tools: [
            {
                name:         "tachyon_get_health",
                description:  "Quick health status of Tachyon services",
                method:       "GET",
                path:         "/tachyon/agent/v1/health",
                input_schema: { type: "object", properties: {} }
            },
            {
                name:         "tachyon_get_snapshot",
                description:  "Full system snapshot (services, connectivity, sections, logs). Use this first.",
                method:       "GET",
                path:         "/tachyon/agent/v1/snapshot",
                input_schema: { type: "object", properties: {} }
            },
            {
                name:         "tachyon_diagnose",
                description:  "Run full self-diagnostics. Returns structured problem list. Also auto-repairs detected issues.",
                method:       "GET",
                path:         "/tachyon/agent/v1/diagnose",
                input_schema: { type: "object", properties: {} }
            },
            {
                name:         "tachyon_get_logs",
                description:  "Last 100 Tachyon-related syslog lines",
                method:       "GET",
                path:         "/tachyon/agent/v1/logs",
                input_schema: { type: "object", properties: {} }
            },
            {
                name:         "tachyon_get_config",
                description:  "Current UCI configuration (secrets masked)",
                method:       "GET",
                path:         "/tachyon/agent/v1/config",
                input_schema: { type: "object", properties: {} }
            },
            {
                name:         "tachyon_heal",
                description:  "Run automatic self-healing. Requires Bearer token.",
                method:       "POST",
                path:         "/tachyon/agent/v1/heal",
                auth:         "bearer",
                input_schema: { type: "object", properties: {} }
            },
            {
                name:         "tachyon_restart",
                description:  "Restart a subsystem: singbox | tachyon | dnsmasq | watchdog. Requires Bearer token.",
                method:       "POST",
                path:         "/tachyon/agent/v1/restart",
                auth:         "bearer",
                input_schema: {
                    type:       "object",
                    required:   ["service"],
                    properties: {
                        service: {
                            type:        "string",
                            enum:        ["singbox", "tachyon", "dnsmasq", "watchdog"],
                            description: "Service to restart"
                        }
                    }
                }
            },
            {
                name:         "tachyon_reload",
                description:  "Reload Tachyon config without full restart. Requires Bearer token.",
                method:       "POST",
                path:         "/tachyon/agent/v1/reload",
                auth:         "bearer",
                input_schema: { type: "object", properties: {} }
            },
            {
                name:         "tachyon_set_config",
                description:  "Set a UCI option. Requires Bearer token.",
                method:       "POST",
                path:         "/tachyon/agent/v1/config/set",
                auth:         "bearer",
                input_schema: {
                    type:       "object",
                    required:   ["section", "option", "value"],
                    properties: {
                        section: { type: "string", description: "UCI section name" },
                        option:  { type: "string", description: "UCI option name" },
                        value:   { type: "string", description: "Value to set" }
                    }
                }
            },
            {
                name:         "tachyon_toggle_section",
                description:  "Enable or disable a routing section. Requires Bearer token.",
                method:       "POST",
                path:         "/tachyon/agent/v1/section/toggle",
                auth:         "bearer",
                input_schema: {
                    type:       "object",
                    required:   ["section"],
                    properties: {
                        section: { type: "string", description: "Section .name" }
                    }
                }
            },
            {
                name:         "tachyon_add_domain",
                description:  "Add a domain to a routing section. Requires Bearer token.",
                method:       "POST",
                path:         "/tachyon/agent/v1/domain/add",
                auth:         "bearer",
                input_schema: {
                    type:       "object",
                    required:   ["section", "domain"],
                    properties: {
                        section: { type: "string", description: "Section .name" },
                        domain:  { type: "string", description: "Domain to add" }
                    }
                }
            }
        ]
    });
}

// ─── WRITE endpoints ──────────────────────────────────────────────────────────

function handle_heal() {
    let res = module_capture(["diagnose-json"]);
    let data = parse_json_safe(res.output);
    command_capture("ucode -L " + shell_quote(LIB_DIR) + " " + shell_quote(WATCHDOG_UC) + " ai-heal > /dev/null 2>&1");
    ok({
        message:      "Self-healing completed",
        issues_found: data ? (data.issues_found || 0) : 0,
        issues_fixed: data ? (data.issues_fixed || 0) : 0,
        overall:      data ? (data.overall || "unknown") : "unknown",
        problems:     data ? (data.problems || []) : []
    });
}

function handle_restart(body) {
    let svc = as_string(body.service || "");
    let allowed = { singbox: 1, tachyon: 1, dnsmasq: 1, watchdog: 1 };
    if (!allowed[svc]) {
        err("Unknown service '" + svc + "'. Allowed: singbox, tachyon, dnsmasq, watchdog");
        return;
    }

    let cmd_map = {
        singbox:  "/etc/init.d/sing-box restart > /dev/null 2>&1",
        tachyon:  "/etc/init.d/tachyon restart > /dev/null 2>&1",
        dnsmasq:  "/etc/init.d/dnsmasq restart > /dev/null 2>&1",
        watchdog: "/usr/bin/tachyon watchdog start-runtime > /dev/null 2>&1"
    };

    system(cmd_map[svc]);
    ok({ message: "Restart of '" + svc + "' initiated" });
}

function handle_reload() {
    system("/usr/bin/tachyon reload > /dev/null 2>&1");
    ok({ message: "Reload initiated" });
}

function handle_config_set(body) {
    let section = as_string(body.section || "");
    let option  = as_string(body.option  || "");
    let value   = as_string(body.value   || "");

    if (section == "" || option == "") {
        err("section and option are required");
        return;
    }

    // Use module-level uci.set() which handles path as package.section.option
    let path = CONFIG_NAME + "." + section + "." + option;
    if (!uci.set(path, value)) {
        err("Failed to set UCI option: " + path);
        return;
    }
    if (!uci.commit(CONFIG_NAME)) {
        err("Failed to commit UCI config", 500);
        return;
    }

    ok({ message: "Set " + path + " = " + value });
}

function handle_section_toggle(body) {
    let section = as_string(body.section || "");
    if (section == "") { err("section is required"); return; }

    let s = uci.get_all(CONFIG_NAME, section);
    if (!s) { err("Section not found: " + section, 404); return; }

    let new_val = (s.enabled == "1") ? "0" : "1";
    if (!uci.set(CONFIG_NAME + "." + section + ".enabled", new_val)) {
        err("Failed to toggle section", 500);
        return;
    }
    uci.commit(CONFIG_NAME);
    system("/usr/bin/tachyon reload > /dev/null 2>&1");

    ok({
        message: "Section '" + section + "' is now " + (new_val == "1" ? "enabled" : "disabled"),
        enabled: new_val == "1"
    });
}

function handle_domain_add(body) {
    let section = as_string(body.section || "");
    let domain  = as_string(body.domain  || "");
    if (section == "" || domain == "") { err("section and domain are required"); return; }

    if (!match(domain, /^[a-zA-Z0-9*._-]+$/)) {
        err("Invalid domain: " + domain);
        return;
    }

    let path = CONFIG_NAME + "." + section + ".domain";
    if (!uci.add_list(path, domain)) {
        err("Failed to add domain (section may not exist or domain already present)");
        return;
    }
    uci.commit(CONFIG_NAME);
    system("/usr/bin/tachyon reload > /dev/null 2>&1");

    ok({ message: "Domain '" + domain + "' added to section '" + section + "'" });
}

function handle_openapi() {
    let spec = {
        openapi: "3.0.3",
        info: {
            title: "Tachyon Router AI Agent API",
            description: "OpenAPI 3.0 REST API for managing Tachyon anti-censorship orchestration & AI Doctor on OpenWrt routers. Supports ChatGPT Custom GPTs, N8N, Dify, and LLM Agents.",
            version: "1.0.0"
        },
        servers: [
            {
                url: "/cgi-bin/tachyon-agent",
                description: "Tachyon Router Agent API Gateway"
            }
        ],
        paths: {
            "/health": {
                get: {
                    summary: "System health check",
                    operationId: "getHealth",
                    responses: { "200": { description: "Health status" } }
                }
            },
            "/snapshot": {
                get: {
                    summary: "Full system state snapshot for LLM context",
                    operationId: "getSnapshot",
                    responses: { "200": { description: "Complete system snapshot" } }
                }
            },
            "/diagnose": {
                get: {
                    summary: "Run system diagnostics and auto-repair",
                    operationId: "getDiagnose",
                    responses: { "200": { description: "Diagnostic report" } }
                }
            },
            "/logs": {
                get: {
                    summary: "Get recent system log entries",
                    operationId: "getLogs",
                    responses: { "200": { description: "System log lines" } }
                }
            },
            "/config": {
                get: {
                    summary: "Get UCI configuration (secrets masked)",
                    operationId: "getConfig",
                    responses: { "200": { description: "UCI settings" } }
                }
            },
            "/tools": {
                get: {
                    summary: "Get tool definitions in OpenAI Function Calling format",
                    operationId: "getTools",
                    responses: { "200": { description: "Tool schemas" } }
                }
            },
            "/ai-doctor/last": {
                get: {
                    summary: "Get last AI Doctor diagnosis report",
                    operationId: "getAiDoctorLast",
                    responses: { "200": { description: "AI Doctor history report" } }
                }
            },
            "/heal": {
                post: {
                    summary: "Trigger autonomous repair cycle",
                    operationId: "postHeal",
                    security: [{ BearerAuth: [] }],
                    responses: { "200": { description: "Repair initiated" } }
                }
            },
            "/ai-doctor/fix": {
                post: {
                    summary: "Apply AI Doctor quick fix codes",
                    operationId: "postAiDoctorFix",
                    security: [{ BearerAuth: [] }],
                    requestBody: {
                        required: true,
                        content: {
                            "application/json": {
                                schema: {
                                    type: "object",
                                    properties: {
                                        fix: { type: "string", example: "clear_dns_cache,start_singbox" }
                                    }
                                }
                            }
                        }
                    },
                    responses: { "200": { description: "Quick fix results" } }
                }
            },
            "/restart": {
                post: {
                    summary: "Restart system service",
                    operationId: "postRestart",
                    security: [{ BearerAuth: [] }],
                    requestBody: {
                        required: true,
                        content: {
                            "application/json": {
                                schema: {
                                    type: "object",
                                    properties: {
                                        service: { type: "string", enum: ["singbox", "tachyon", "dnsmasq", "watchdog"] }
                                    }
                                }
                            }
                        }
                    },
                    responses: { "200": { description: "Restart outcome" } }
                }
            },
            "/reload": {
                post: {
                    summary: "Reload firewall rules & configs",
                    operationId: "postReload",
                    security: [{ BearerAuth: [] }],
                    responses: { "200": { description: "Reload status" } }
                }
            },
            "/config/set": {
                post: {
                    summary: "Set UCI configuration option",
                    operationId: "postConfigSet",
                    security: [{ BearerAuth: [] }],
                    requestBody: {
                        required: true,
                        content: {
                            "application/json": {
                                schema: {
                                    type: "object",
                                    properties: {
                                        section: { type: "string" },
                                        option: { type: "string" },
                                        value: { type: "string" }
                                    }
                                }
                            }
                        }
                    },
                    responses: { "200": { description: "UCI update result" } }
                }
            }
        },
        components: {
            securitySchemes: {
                BearerAuth: {
                    type: "http",
                    scheme: "bearer",
                    bearerFormat: "Secret Token"
                }
            }
        }
    };
    write_json(spec);
}

function handle_ai_doctor_last() {
    let raw = fs.readfile("/tmp/ai_doctor_last.json");
    if (!raw) {
        err("No previous AI Doctor report found", 404);
        return;
    }
    let data = parse_json_safe(raw);
    if (!data) {
        err("Corrupted AI Doctor history file", 500);
        return;
    }
    ok(data);
}

function handle_ai_doctor_fix(body) {
    let fix_code = as_string(body.fix || "");
    if (fix_code == "" && type(body.fixes) == "array") {
        fix_code = join(",", body.fixes);
    }
    if (fix_code == "") {
        err("fix (code string) or fixes (string array) is required");
        return;
    }

    let res = command_capture("/usr/bin/tachyon apply_quick_fix " + shell_quote(fix_code));
    let parsed = parse_json_safe(res.output);
    if (parsed) {
        write_json(parsed);
    } else {
        ok({ message: "Quick fix command executed", code: fix_code });
    }
}

// ─── Dispatcher ───────────────────────────────────────────────────────────────

let path_arg = as_string(ARGV[0] || "");
let method   = uc(as_string(ARGV[1] || "GET"));
let body     = parse_json_safe(ARGV[2] || "{}") || {};
let bearer   = as_string(ARGV[3] || "");

let route = replace(path_arg, /^\/tachyon\/agent\/v1/, "");
if (route == "") route = "/";

if (method == "GET") {
    if (route == "/health" || route == "/health/")
        handle_health();
    else if (route == "/snapshot" || route == "/snapshot/")
        handle_snapshot();
    else if (route == "/diagnose" || route == "/diagnose/")
        handle_diagnose();
    else if (route == "/logs" || route == "/logs/")
        handle_logs();
    else if (route == "/config" || route == "/config/")
        handle_config();
    else if (route == "/tools" || route == "/tools/")
        handle_tools();
    else if (route == "/ai-doctor/last" || route == "/ai-doctor/last/")
        handle_ai_doctor_last();
    else if (route == "/openapi.json" || route == "/openapi.json/")
        handle_openapi();
    else
        err("Unknown endpoint: GET " + route, 404);
} else if (method == "POST") {
    if (!check_write_auth(bearer)) {
        err("Unauthorized. Configure agent_api_token in UCI and use Bearer token.", 401);
    } else {
        if (route == "/heal" || route == "/heal/")
            handle_heal();
        else if (route == "/restart" || route == "/restart/")
            handle_restart(body);
        else if (route == "/reload" || route == "/reload/")
            handle_reload();
        else if (route == "/config/set")
            handle_config_set(body);
        else if (route == "/section/toggle")
            handle_section_toggle(body);
        else if (route == "/domain/add")
            handle_domain_add(body);
        else if (route == "/ai-doctor/fix" || route == "/ai-doctor/fix/")
            handle_ai_doctor_fix(body);
        else
            err("Unknown endpoint: POST " + route, 404);
    }
} else {
    err("Method not allowed: " + method, 405);
}