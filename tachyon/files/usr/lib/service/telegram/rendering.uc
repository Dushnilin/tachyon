#!/usr/bin/env ucode
//
// Telegram bot UI rendering, schemas, formatting and validation helpers.
// Extracted from service/telegram.uc (Branch 7 god-module refactor).
//

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let i18n = require("service.i18n");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";

let as_string = common.as_string;
let shell_quote = common.shell_quote;
let command_from_args = common.command_from_args;
let command_capture = common.command_capture;
let command_output_from_args = common.command_output_from_args;

function get_t() {
    let cfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
    return i18n.bind(cfg.language || "en");
}

function escape_html(text) {
    text = replace(as_string(text), /&/g, "&amp;");
    text = replace(text, /</g, "&lt;");
    text = replace(text, />/g, "&gt;");
    return text;
}

function ipv4_to_int(addr) {
    let parts = split(addr, ".");
    if (length(parts) != 4) return 0;
    return (int(parts[0]) * 16777216) + (int(parts[1]) * 65536) + (int(parts[2]) * 256) + int(parts[3]);
}

function cidr_match_v4(target, cidr) {
    let cp = split(cidr, "/");
    if (length(cp) != 2) return false;
    let mask_len = int(cp[1]);
    if (mask_len < 0 || mask_len > 32) return false;
    if (mask_len == 0) return true;
    let mask = 0;
    for (let i = 0; i < mask_len; i++)
        mask = mask | (1 << (31 - i));
    let t_int = ipv4_to_int(target);
    let n_int = ipv4_to_int(cp[0]);
    return (t_int & mask) == (n_int & mask);
}

function format_bytes(b) {
    b = double(b || 0);
    if (b > 1073741824) return sprintf("%.2f GB", b / 1073741824);
    if (b > 1048576) return sprintf("%.2f MB", b / 1048576);
    if (b > 1024) return sprintf("%.2f KB", b / 1024);
    return sprintf("%d B", b);
}

let setting_schema = {
    settings: {
        dns_type: "dns_type",
        dns_server: "dns_server",
        bootstrap_dns_server: "bootstrap_dns_server",
        dns_strategy: "dns_strategy",
        dns_detour_enabled: "dns_detour_enabled",
        source_network_interfaces: "source_network_interfaces",
        enable_output_network_interface: "enable_output_network_interface",
        enable_badwan_interface_monitoring: "enable_badwan_interface_monitoring",
        enable_yacd: "enable_yacd",
        disable_quic: "disable_quic",
        block_doh: "block_doh",
        list_update_enabled: "list_update_enabled",
        component_update_check_enabled: "component_update_check_enabled",
        download_lists_via_proxy: "download_lists_via_proxy",
        download_components_via_proxy: "download_components_via_proxy",
        dont_touch_dhcp: "dont_touch_dhcp",
        isolate_p2p: "isolate_p2p",
        log_level: "log_level",
        exclude_ntp: "exclude_ntp",
        route_router_traffic: "route_router_traffic",
        route_router_traffic_section: "route_router_traffic_section",
        shutdown_correctly: "shutdown_correctly",
        smart_detect: "smart_detect",
        smart_detect_sections: "smart_detect_sections"
    },
    telegram: {
        enabled: "enabled",
        bot_token: "bot_token",
        admin_ids: "admin_ids",
        poll_interval: "poll_interval",
        notify_crash: "notify_crash",
        notify_restart: "notify_restart",
        notify_server_switch: "notify_server_switch",
        notify_subscription: "notify_subscription",
        notify_cert: "notify_cert",
        notify_dns_leak: "notify_dns_leak",
        daily_report_enabled: "daily_report_enabled",
        daily_report_hour: "daily_report_hour",
        quiet_hours_enabled: "quiet_hours_enabled",
        quiet_hours_start: "quiet_hours_start",
        quiet_hours_end: "quiet_hours_end",
        fallback_socks: "fallback_socks",
        language: "language"
    },
    subscription_url: {
        section: "section",
        url: "url",
        auto_user_agent: "auto_user_agent",
        user_agent: "user_agent",
        auto_hwid: "auto_hwid",
        subscription_update_enabled: "subscription_update_enabled",
        subscription_update_interval: "subscription_update_interval",
        download_via_proxy_enabled: "download_via_proxy_enabled",
        show_dashboard_metadata: "show_dashboard_metadata",
        prefix_nodes: "prefix_nodes",
        node_prefix: "node_prefix",
        include_urltest_groups: "include_urltest_groups",
        hide_urltest_group_outbounds: "hide_urltest_group_outbounds",
        hide_detour_outbounds: "hide_detour_outbounds"
    },
    server: {
        label: "label",
        enabled: "enabled",
        protocol: "protocol",
        routing_mode: "routing_mode"
    }
};

function get_schema_label(stype, key, custom_t) {
    let t = custom_t || get_t();
    if (setting_schema[stype] && setting_schema[stype][key])
        return t(setting_schema[stype][key]);
    return t(key);
}

function is_boolean_key(key) {
    let b = ["enabled", "auto_user_agent", "auto_hwid", "subscription_update_enabled",
             "download_via_proxy_enabled", "show_dashboard_metadata", "prefix_nodes",
             "include_urltest_groups", "hide_urltest_group_outbounds", "hide_detour_outbounds",
             "dns_detour_enabled", "enable_output_network_interface", "enable_badwan_interface_monitoring",
             "enable_yacd", "disable_quic", "block_doh", "list_update_enabled", "component_update_check_enabled",
             "download_lists_via_proxy", "download_components_via_proxy", "dont_touch_dhcp",
             "isolate_p2p", "exclude_ntp", "route_router_traffic", "shutdown_correctly", "smart_detect",
             "notify_crash", "notify_restart", "notify_server_switch", "notify_subscription", "notify_cert", "notify_dns_leak",
             "daily_report_enabled", "quiet_hours_enabled"];
    for (let x in b) if (x == key) return true;
    return false;
}

function is_list_key(key) {
    let l = ["dns_server", "bootstrap_dns_server", "source_network_interfaces",
             "badwan_monitored_interfaces", "smart_detect_sections"];
    for (let x in l) if (x == key) return true;
    return false;
}

// ─── Safe command executor (whitelist-only, no shell interpretation) ─────────

let safe_exec_patterns = {
    tachyon: {
        bin: "/usr/bin/tachyon",
        min_args: 0,
        max_args: 1,
        usage: "tachyon [get_status|doctor|show_sing_box_version|show_version]"
    },
    logread: {
        bin: "/sbin/logread",
        min_args: 0,
        max_args: 1,
        extra_pattern: /^-t$/,
        usage: "logread [-t]"
    },
    ubus: {
        bin: "/bin/ubus",
        args: [ "call", "system", "board" ],
        exact: true,
        usage: "ubus call system board"
    },
    df: {
        bin: "/bin/df",
        args: [ "-h" ],
        exact: true,
        usage: "df -h"
    },
    free: {
        bin: "/usr/bin/free",
        min_args: 0,
        max_args: 0,
        usage: "free"
    },
    uptime: {
        bin: "/usr/bin/uptime",
        min_args: 0,
        max_args: 0,
        usage: "uptime"
    },
    nft: {
        bin: "/usr/sbin/nft",
        args: [ "list", "tables" ],
        exact: true,
        usage: "nft list tables"
    }
};

function parse_command_words(text) {
    let words = [];
    let cur = "";
    let quote = null;
    for (let i = 0; i < length(text); i++) {
        let ch = substr(text, i, 1);
        if (quote) {
            if (ch == quote) quote = null;
            else cur += ch;
            continue;
        }
        if (ch == "'" || ch == "\"") { quote = ch; continue; }
        if (ch == " " || ch == "\t" || ch == "\n") {
            if (cur != "") { push(words, cur); cur = ""; }
            continue;
        }
        cur += ch;
    }
    if (cur != "") push(words, cur);
    return { words: words, error: quote ? "unclosed quote" : null };
}

function safe_allowed_commands_text() {
    let lines = [];
    for (let k in keys(safe_exec_patterns)) {
        let p = safe_exec_patterns[k];
        push(lines, "<code>" + p.usage + "</code>");
    }
    return join("\n", lines);
}

function safe_execute(exec_text, custom_t) {
    let t = custom_t || get_t();
    let parsed = parse_command_words(exec_text);
    if (parsed.error || length(parsed.words) == 0)
        return { status: 1, output: t("err_invalid_format") };

    let argv = parsed.words;
    let command_name = argv[0];
    let base_match = match(command_name, /([^\/]+)$/);
    let base = base_match ? base_match[1] : command_name;

    let policy = safe_exec_patterns[base];
    if (!policy)
        return { status: 1, output: t("err_not_allowed", base) };

    let rest = slice(argv, 1);

    if (policy.exact) {
        if (length(rest) != length(policy.args)) return { status: 1, output: t("err_args_mismatch") };
        for (let i = 0; i < length(rest); i++)
            if (rest[i] != policy.args[i]) return { status: 1, output: t("err_args_mismatch") };
    } else {
        if (length(rest) < policy.min_args || length(rest) > policy.max_args) return { status: 1, output: t("err_wrong_arg_count") };
        if (policy.extra_pattern) {
            for (let arg in rest)
                if (!match(arg, policy.extra_pattern)) return { status: 1, output: t("err_arg_not_allowed", arg) };
        }
        if (base == "tachyon" && length(rest) == 1) {
            let allowed_sub = { get_status: 1, doctor: 1, show_version: 1, show_sing_box_version: 1, show_config: 1, get_system_info: 1 };
            if (!allowed_sub[rest[0]]) return { status: 1, output: t("err_subcmd_not_allowed", rest[0]) };
        }
    }

    let full_argv = [ policy.bin ];
    for (let a in rest) push(full_argv, a);
    return command_capture(command_from_args(full_argv));
}

function extract_clean_fptn_token(raw) {
    let text = trim(as_string(raw));
    if (text == "") return "";
    let m = match(text, /(access_token|token)[[:space:]:=]+["']?([A-Za-z0-9_.-]{8,})["']?/i);
    if (m && m[2])
        return trim(m[2]);
    m = match(text, /^["']([A-Za-z0-9_.-]{8,})["']$/);
    if (m && m[1])
        return trim(m[1]);
    m = match(text, /^([A-Za-z0-9_.-]{8,})$/);
    if (m && m[1])
        return trim(m[1]);
    return "";
}

function mask_fptn_token(tok, custom_t) {
    let t = custom_t || get_t();
    tok = as_string(tok);
    if (length(tok) > 8)
        return "••••••••" + substr(tok, length(tok) - 4);
    if (length(tok) > 0)
        return "••••";
    return t("status_disabled");
}

function backup_archive_members(dl_path) {
    let out = command_output_from_args([ "tar", "-tzf", dl_path ]);
    let members = [];
    for (let line in split(out, "\n")) {
        line = trim(line);
        if (line == "") continue;
        push(members, line);
    }
    return members;
}

function backup_archive_safe(members) {
    for (let m in members) {
        if (substr(m, 0, 1) == "/") return { ok: false, reason: "absolute path: " + m };
        if (match(m, /\.\./)) return { ok: false, reason: "path traversal: " + m };
        if (m != "config/tachyon" && !match(m, /^tachyon\//))
            return { ok: false, reason: "unexpected member: " + m };
    }
    return { ok: true };
}

function backup_extract_dir() {
    let ts = time();
    let rand = sprintf("%04x", clock()[1] & 0xFFFF);
    let dir = "/etc/.tachyon/restore_" + as_string(ts) + "_" + rand;
    system("mkdir -p " + shell_quote(dir) + " 2>/dev/null");
    return dir;
}

function config_sane_preview(path) {
    let data = fs.readfile(path);
    if (data == null) return false;
    return match(data, /(^|\n)[ \t]*config[ \t]+[A-Za-z0-9_-]+/) != null;
}

function build_label(sha, fingerprint) {
    sha = as_string(sha);
    if (sha != "")
        return length(sha) > 7 ? substr(sha, 0, 7) : sha;
    fingerprint = as_string(fingerprint);
    if (fingerprint == "")
        return "";
    let published = match(fingerprint, /pub=([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}:[0-9]{2})/);
    if (published)
        return as_string(published[1]) + " " + as_string(published[2]);
    return length(fingerprint) > 24 ? substr(fingerprint, 0, 24) : fingerprint;
}

function build_transition(comp) {
    let from = build_label(comp.current_sha, comp.current_build);
    let to = build_label(comp.latest_sha, comp.latest_build);
    if (from == "" || to == "" || from == to)
        return to != "" ? "<code>" + escape_html(to) + "</code>" : "";
    return "<code>" + escape_html(from) + "</code> ➡️ <code>" + escape_html(to) + "</code>";
}

function build_identity_key(comp) {
    let sha = as_string(comp.latest_sha);
    return sha != "" ? sha : as_string(comp.latest_build);
}

function normalize_mac(mac) {
    mac = uc(trim(as_string(mac)));
    if (!match(mac, /^[0-9A-F]{2}(:[0-9A-F]{2}){5}$/)) return null;
    return mac;
}

function find_mac_block_rules(c, mac) {
    let found = [];
    c.foreach("firewall", "rule", function(r) {
        if (r.target == "REJECT" && r.src_mac && uc(as_string(r.src_mac)) == mac)
            push(found, r[".name"]);
    });
    return found;
}

function valid_updatable_component(name) {
    name = as_string(name);
    let allowed = {
        tachyon: 1,
        sing_box: 1,
        "sing-box": 1,
        zapret: 1,
        zapret2: 1,
        byedpi: 1
    };
    return allowed[name];
}

return {
    CONFIG_NAME,
    get_t,
    escape_html,
    ipv4_to_int,
    cidr_match_v4,
    format_bytes,
    setting_schema,
    get_schema_label,
    is_boolean_key,
    is_list_key,
    safe_exec_patterns,
    parse_command_words,
    safe_allowed_commands_text,
    safe_execute,
    extract_clean_fptn_token,
    mask_fptn_token,
    backup_archive_members,
    backup_archive_safe,
    backup_extract_dir,
    config_sane_preview,
    build_label,
    build_transition,
    build_identity_key,
    normalize_mac,
    find_mac_block_rules,
    valid_updatable_component
};
