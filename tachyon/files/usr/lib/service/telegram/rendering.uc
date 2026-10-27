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
        router_name: "router_name",
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
        // The bot already writes this when adding a URL and already shows it as
        // an on/off icon; it was missing here, so the key fell through to the
        // untranslated branch and had no label.
        enabled: "enabled",
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
    },
    section: {
        label: "label",
        enabled: "enabled",
        action: "action",
        routing_mode: "routing_mode",
        target: "target",
        dns_type: "dns_type",
        dns_server: "dns_server",
        condition_refs: "condition_refs",
        condition_expression: "condition_expression",
        outbound_source_refs: "outbound_source_refs",
        outbound_group_refs: "outbound_group_refs",
        balancer_refs: "balancer_refs",
        group_members: "group_members",
        match_all: "match_all",
        geoip_country: "geoip_country",
        geoip_mode: "geoip_mode",
        ports: "ports"
    },
    condition: {
        label: "label",
        condition_expression: "condition_expression",
        match_all: "match_all",
        user_domains: "user_domains",
        domain_suffix: "domain_suffix",
        domain: "domain",
        domain_keyword: "domain_keyword",
        domain_regex: "domain_regex",
        ip_cidr: "ip_cidr",
        subnets: "subnets",
        source_ip_cidr: "source_ip_cidr",
        fully_routed_ips: "fully_routed_ips",
        excluded_ips: "excluded_ips",
        devices: "devices",
        device_ip: "device_ip",
        device_mac: "device_mac",
        source_macs: "source_macs",
        ports: "ports",
        dscp: "dscp",
        community_lists: "community_lists",
        rule_set: "rule_set",
        domain_ip_lists: "domain_ip_lists",
        geoip_country: "geoip_country",
        geoip_mode: "geoip_mode"
    },
    outbound_source: {
        label: "label",
        enabled: "enabled",
        source_type: "source_type",
        url: "url",
        proxy_links: "proxy_links",
        interface: "interface",
        zapret2_strategy: "zapret2_strategy",
        zapret_strategy: "zapret_strategy",
        byedpi_args: "byedpi_args",
        desync_mode: "desync_mode",
        subscription_update_enabled: "subscription_update_enabled",
        subscription_update_interval: "subscription_update_interval",
        download_via_proxy_enabled: "download_via_proxy_enabled",
        prefix_nodes: "prefix_nodes",
        node_prefix: "node_prefix",
        include_urltest_groups: "include_urltest_groups"
    },
    outbound_group: {
        label: "label",
        enabled: "enabled",
        source_refs: "source_refs",
        server_refs: "server_refs",
        name_filter_regex: "name_filter_regex",
        name_exclude_regex: "name_exclude_regex"
    },
    balancer: {
        label: "label",
        enabled: "enabled",
        mode: "mode",
        source_refs: "source_refs",
        group_refs: "group_refs",
        testing_url: "testing_url",
        check_interval: "check_interval",
        tolerance: "tolerance",
        idle_timeout: "idle_timeout"
    }
};

function get_schema_label(stype, key, custom_t) {
    let t = custom_t || get_t();
    if (setting_schema[stype] && setting_schema[stype][key])
        return t(setting_schema[stype][key]);
    return t(key);
}

function is_boolean_key(key) {
    // disable_quic is a three-mode value (off/tunneled/all), not a flag: a
    // checkbox would render both new modes as "off" and a toggle would erase
    // them. It goes through the plain string branch instead.
    let b = ["enabled", "auto_user_agent", "auto_hwid", "subscription_update_enabled",
             "download_via_proxy_enabled", "show_dashboard_metadata", "prefix_nodes",
             "include_urltest_groups", "hide_urltest_group_outbounds", "hide_detour_outbounds",
             "dns_detour_enabled", "enable_output_network_interface", "enable_badwan_interface_monitoring",
             "enable_yacd", "block_doh", "list_update_enabled", "component_update_check_enabled",
             "download_lists_via_proxy", "download_components_via_proxy", "dont_touch_dhcp",
             "isolate_p2p", "exclude_ntp", "route_router_traffic", "shutdown_correctly", "smart_detect",
             "notify_crash", "notify_restart", "notify_server_switch", "notify_subscription", "notify_cert", "notify_dns_leak",
             "daily_report_enabled", "quiet_hours_enabled", "match_all"];
    for (let x in b) if (x == key) return true;
    return false;
}

function is_list_key(key) {
    let l = ["dns_server", "bootstrap_dns_server", "source_network_interfaces",
             "badwan_monitored_interfaces", "smart_detect_sections", "admin_ids",
             "condition_refs", "outbound_source_refs", "outbound_group_refs", "balancer_refs", "group_members",
             "source_refs", "group_refs", "server_refs",
             "user_domains", "domain", "domain_suffix", "domain_keyword", "domain_regex",
             "ip_cidr", "ip", "subnets", "source_ip_cidr", "fully_routed_ips", "excluded_ips",
             "devices", "device_ip", "device_mac", "source_macs", "ports", "port", "dscp",
             "community_lists", "rule_set", "rule_set_with_subnets", "domain_ip_lists",
             "geoip_country", "proxy_links"];
    for (let x in l) if (x == key) return true;
    return false;
}

// ─── Safe command executor (whitelist-only, no shell interpretation) ─────────

let safe_exec_patterns = {
    tachyon: {
        bin: "/usr/bin/tachyon",
        min_args: 0,
        max_args: 1,
        usage: "tachyon [get_status|doctor|show_sing_box_version|show_version|restore_native_internet|failsafe_restore|stop|restart|reload]"
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
            let allowed_sub = {
                get_status: 1,
                doctor: 1,
                show_version: 1,
                show_sing_box_version: 1,
                show_config: 1,
                get_system_info: 1,
                restore_native_internet: 1,
                failsafe_restore: 1,
                stop: 1,
                restart: 1,
                reload: 1
            };
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
        tachyon_core: 1,
        "tachyon-core": 1,
        sing_box: 1,
        "sing-box": 1,
        steer: 1,
        zapret: 1,
        zapret2: 1,
        byedpi: 1
    };
    return allowed[name];
}

function component_display_title(comp) {
    if (type(comp) == "object") {
        let name = as_string(comp.component || "");
        let rel_url = as_string(comp.release_url || "");
        let msg = as_string(comp.message || "");
        let cur_v = as_string(comp.current_version || "");
        if (name == "tachyon_core" || name == "tachyon-core")
            return "tachyon-core";
        if (name == "sing_box" || name == "sing-box") {
            if (index(rel_url, "tachyon-core") >= 0 || index(msg, "tachyon-core") >= 0 || index(cur_v, "tachyon") >= 0)
                return "tachyon-core";
            let marker = trim(as_string(fs.readfile("/etc/tachyon/tachyon-core-variant") || fs.readfile("/etc/tachyon/sing-box-variant") || ""));
            if (marker == "" || marker == "tachyon-core")
                return "tachyon-core";
            return "sing-box";
        }
        return name;
    }
    let sname = as_string(comp || "");
    if (sname == "tachyon_core" || sname == "tachyon-core")
        return "tachyon-core";
    if (sname == "sing_box" || sname == "sing-box") {
        let marker = trim(as_string(fs.readfile("/etc/tachyon/tachyon-core-variant") || fs.readfile("/etc/tachyon/sing-box-variant") || ""));
        if (marker == "" || marker == "tachyon-core")
            return "tachyon-core";
        return "sing-box";
    }
    return sname;
}

function clean_release_notes(raw_notes) {
    let text = trim(replace(as_string(raw_notes || ""), /\r/g, ""));
    if (text == "")
        return "";
    let lines = split(text, "\n");
    let out = [];
    for (let line in lines) {
        let trimmed = trim(line);
        if (index(trimmed, "img.shields.io") >= 0 || match(trimmed, /^\[!\[.*\]\(https?:\/\/.*\)\]\(https?:\/\/.*\)$/))
            continue;
        if (trimmed == "---" && length(out) <= 2)
            continue;
        push(out, line);
    }
    return trim(join("\n", out));
}

// ---------------------------------------------------------------------------
// The modular layout: conditions, outbound sources and balancers
// ---------------------------------------------------------------------------
//
// A section no longer carries its conditions and its server sources itself.
// The conditions live in reusable "condition" sections the section points
// at, the sources in "outbound_source" sections, and the auto-selection
// rules in "balancer" sections. A bot that only reads the section's own
// fields therefore sees empty lists.
//
// These helpers read the section the way the generator reads it: the
// section's own fields plus the ones its linked conditions carry.

// The condition sections a section is built from: the ones it references
// and the ones they are composed of (recursively traversing composite
// condition_expression and condition_refs).
function section_condition_sections(section) {
    let result = [];
    let seen = {};
    if (type(section) != "object")
        return result;

    let visit = null;
    visit = function(cond) {
        if (type(cond) != "object")
            return;
        let name = common.option(cond, ".name", "");
        if (name == "" || seen[name])
            return;
        seen[name] = true;
        push(result, cond);

        for (let ref in common.list_option(cond, "condition_refs"))
            visit(uci_core.get_all(CONFIG_NAME, ref));

        let c_expr = trim(as_string(common.option(cond, "condition_expression", "")));
        if (c_expr != "") {
            for (let tok in split(c_expr, /[^A-Za-z0-9_]+/)) {
                let ut = uc(tok);
                if (tok == "" || ut == "AND" || ut == "OR" || ut == "NOT")
                    continue;
                let sub = uci_core.get_all(CONFIG_NAME, tok);
                if (type(sub) == "object" && (sub[".type"] == "condition" || sub[".type"] == null))
                    visit(sub);
            }
        }
    };

    // A section may reference its conditions by name, or name them in a
    // free-text expression - both are how the interface writes them.
    for (let ref in common.list_option(section, "condition_refs"))
        visit(uci_core.get_all(CONFIG_NAME, ref));

    let expr = trim(as_string(common.option(section, "condition_expression", "")));
    if (expr != "") {
        for (let tok in split(expr, /[^A-Za-z0-9_]+/)) {
            let ut = uc(tok);
            if (tok == "" || ut == "AND" || ut == "OR" || ut == "NOT")
                continue;
            let sub = uci_core.get_all(CONFIG_NAME, tok);
            if (type(sub) == "object" && (sub[".type"] == "condition" || sub[".type"] == null))
                visit(sub);
        }
        let c = uci_core.cursor();
        if (c) {
            c.load(CONFIG_NAME);
            let conditions = c.get_all(CONFIG_NAME, "condition");
            for (let name in conditions) {
                if (match(expr, name) != null || match(expr, name + " ") != null)
                    visit(conditions[name]);
            }
        }
    }

    return result;
}

// The condition sections a section is built from, plus the section itself.
// The section's own fields count - a config from before the modular layout
// still holds them there.
function section_own_and_conditions(section) {
    let result = [];
    if (type(section) == "object")
        push(result, section);
    for (let cond in section_condition_sections(section))
        push(result, cond);
    return result;
}

// The primary atomic condition linked to a section (if any), where new rule
// items added via the Telegram bot should be stored.
function section_primary_atomic_condition(section) {
    let conds = section_condition_sections(section);
    for (let cond in conds) {
        if (trim(as_string(common.option(cond, "condition_expression", ""))) == "")
            return cond;
    }
    return length(conds) > 0 ? conds[0] : null;
}

function section_match_all_enabled(section) {
    for (let src in section_own_and_conditions(section)) {
        if (as_string(common.option(src, "match_all", "0")) == "1")
            return true;
    }
    return false;
}

// The values of one condition key across the section and its conditions.
function section_condition_values(section, key) {
    let result = [];
    let seen = {};
    let add_val = function(v) {
        v = trim(as_string(v));
        if (v == "" || seen[v])
            return;
        seen[v] = true;
        push(result, v);
    };

    let keys_to_read = [ key ];
    if (key == "src_ip" || key == "source_ip_cidr")
        keys_to_read = [ "src_ip", "source_ip_cidr", "fully_routed_ips", "device_ip" ];
    else if (key == "src_mac" || key == "source_macs")
        keys_to_read = [ "src_mac", "source_macs", "device_mac" ];
    else if (key == "src_device" || key == "devices")
        keys_to_read = [ "src_device", "devices" ];
    else if (key == "ports" || key == "port")
        keys_to_read = [ "ports", "port" ];

    for (let src in section_own_and_conditions(section)) {
        for (let k in keys_to_read) {
            for (let value in common.list_option(src, k)) {
                for (let tok in split(as_string(value), /[\r\n,;\t ]+/)) {
                    if (tok == "")
                        continue;
                    if (key == "domain" && (substr(tok, 0, 7) == "domain:" || substr(tok, 0, 8) == "keyword:" || substr(tok, 0, 6) == "regex:" || substr(tok, 0, 7) == "regexp:"))
                        continue;
                    if (key == "domain" && substr(tok, 0, 5) == "full:")
                        tok = substr(tok, 5);
                    else if (key == "domain_suffix" && substr(tok, 0, 7) == "domain:")
                        tok = substr(tok, 7);
                    else if (key == "domain_keyword" && substr(tok, 0, 8) == "keyword:")
                        tok = substr(tok, 8);
                    else if (key == "domain_regex" && (substr(tok, 0, 6) == "regex:" || substr(tok, 0, 7) == "regexp:"))
                        tok = substr(tok, index(tok, ":") + 1);
                    add_val(tok);
                }
            }
            let text_val = trim(as_string(common.option(src, k + "_text", "")));
            if (text_val != "") {
                for (let tok in split(text_val, /[\r\n,;\t ]+/)) {
                    if (tok != "")
                        add_val(tok);
                }
            }
        }

        // Also extract prefixed or bare domain entries stored in user_domains / domain
        if (key == "domain_suffix" || key == "domain" || key == "domain_keyword" || key == "domain_regex") {
            let extra_tokens = [];
            for (let uk in [ "user_domains", "domain" ]) {
                for (let v in common.list_option(src, uk)) {
                    for (let t in split(as_string(v), /[\r\n,;\t ]+/))
                        if (t != "") push(extra_tokens, { src_key: uk, val: t });
                }
                let ut = trim(as_string(common.option(src, uk + "_text", "")));
                if (ut != "") {
                    for (let t in split(ut, /[\r\n,;\t ]+/))
                        if (t != "") push(extra_tokens, { src_key: uk, val: t });
                }
            }
            for (let item in extra_tokens) {
                let tok = item.val;
                if (substr(tok, 0, 5) == "full:") {
                    if (key == "domain") add_val(substr(tok, 5));
                } else if (substr(tok, 0, 7) == "domain:") {
                    if (key == "domain_suffix") add_val(substr(tok, 7));
                } else if (substr(tok, 0, 8) == "keyword:") {
                    if (key == "domain_keyword") add_val(substr(tok, 8));
                } else if (substr(tok, 0, 6) == "regex:" || substr(tok, 0, 7) == "regexp:") {
                    if (key == "domain_regex") add_val(substr(tok, index(tok, ":") + 1));
                } else if (item.src_key == "user_domains" && key == "domain_suffix") {
                    let cleaned = substr(tok, 0, 1) == "." ? substr(tok, 1) : tok;
                    add_val(cleaned);
                }
            }
        }
    }
    return result;
}

// The server sources a section draws from: the outbound_source sections it
// references directly, via outbound_group_refs, or via balancer_refs, plus
// the legacy subscription_url children it still carries.
function section_outbound_sources(section) {
    let result = [];
    let seen = {};
    if (type(section) != "object")
        return result;

    let add = function(src) {
        if (type(src) != "object")
            return;
        let name = common.option(src, ".name", "");
        if (name == "" || seen[name])
            return;
        seen[name] = true;
        push(result, src);
    };

    let add_group = function(grp) {
        if (type(grp) != "object")
            return;
        for (let sref in common.list_option(grp, "source_refs"))
            add(uci_core.get_all(CONFIG_NAME, sref));
    };

    for (let ref in common.list_option(section, "outbound_source_refs"))
        add(uci_core.get_all(CONFIG_NAME, ref));

    for (let gref in common.list_option(section, "outbound_group_refs"))
        add_group(uci_core.get_all(CONFIG_NAME, gref));

    for (let bref in common.list_option(section, "balancer_refs")) {
        let bal = uci_core.get_all(CONFIG_NAME, bref);
        if (type(bal) != "object")
            continue;
        for (let sref in common.list_option(bal, "source_refs"))
            add(uci_core.get_all(CONFIG_NAME, sref));
        for (let gref in common.list_option(bal, "group_refs"))
            add_group(uci_core.get_all(CONFIG_NAME, gref));
        for (let lvl in common.list_option(bal, "outbound_group_levels")) {
            for (let part in split(as_string(lvl), /[,;\t ]+/)) {
                if (substr(part, 0, 7) == "source:")
                    add(uci_core.get_all(CONFIG_NAME, substr(part, 7)));
                else if (substr(part, 0, 6) == "group:")
                    add_group(uci_core.get_all(CONFIG_NAME, substr(part, 6)));
            }
        }
    }

    let c = uci_core.cursor();
    if (c) {
        c.load(CONFIG_NAME);
        let all = c.get_all(CONFIG_NAME);
        for (let name in all) {
            if (all[name][".type"] == "subscription_url" && all[name].section == common.option(section, ".name", ""))
                add(all[name]);
        }
    }

    return result;
}

function section_has_fptn(section) {
    if (type(section) != "object")
        return false;
    if (as_string(common.option(section, "action", "")) == "fptn")
        return true;
    for (let src in section_outbound_sources(section)) {
        if (as_string(common.option(src, "source_type", "")) == "fptn")
            return true;
    }
    return false;
}

function section_fptn_token(section) {
    if (type(section) != "object")
        return "";
    let tok = trim(as_string(common.option(section, "access_token", "")));
    if (tok != "")
        return tok;
    for (let src in section_outbound_sources(section)) {
        if (as_string(common.option(src, "source_type", "")) == "fptn") {
            let st = trim(as_string(common.option(src, "access_token", "")));
            if (st != "")
                return st;
        }
    }
    return "";
}

// The balancers a section uses: the reusable ones it references and the
// legacy urltest/priority_group children it still carries.
function section_balancers(section) {
    let result = [];
    let seen = {};
    if (type(section) != "object")
        return result;

    let add = function(bal) {
        if (type(bal) != "object")
            return;
        let name = common.option(bal, ".name", "");
        if (name == "" || seen[name])
            return;
        seen[name] = true;
        push(result, bal);
    };

    for (let ref in common.list_option(section, "balancer_refs"))
        add(uci_core.get_all(CONFIG_NAME, ref));

    let c = uci_core.cursor();
    if (c) {
        c.load(CONFIG_NAME);
        let all = c.get_all(CONFIG_NAME);
        let sec_name = common.option(section, ".name", "");
        for (let name in all) {
            let child = all[name];
            if ((child[".type"] == "urltest" || child[".type"] == "priority_group") && child.section == sec_name)
                add(child);
        }
    }

    return result;
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
    section_condition_sections,
    section_own_and_conditions,
    section_primary_atomic_condition,
    section_match_all_enabled,
    section_condition_values,
    section_outbound_sources,
    section_has_fptn,
    section_fptn_token,
    section_balancers,
    backup_archive_members,
    backup_archive_safe,
    backup_extract_dir,
    config_sane_preview,
    build_label,
    build_transition,
    build_identity_key,
    normalize_mac,
    find_mac_block_rules,
    valid_updatable_component,
    component_display_title,
    clean_release_notes
};
