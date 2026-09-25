#!/usr/bin/env ucode
//
// Telegram bot command views and diagnostic executors.
// Extracted from service/telegram.uc (Branch 7 god-module refactor).
//

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let connections = require("config.connections");
let dns_presets = require("singbox.dns_presets");
let api = require("service.api");
let i18n = require("service.i18n");

let rendering = require("service.telegram.rendering");
let transport = require("service.telegram.transport");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const BIN_PATH = getenv("TACHYON_BIN") || "/usr/bin/tachyon";

let as_string = common.as_string;
let option = common.option;
let bool_option = common.bool_option;
let int_option = common.int_option;
let list_option = common.list_option;
let shell_quote = common.shell_quote;
let object_or_empty = common.object_or_empty;
let command_status = common.command_status;
let command_success_from_args = common.command_success_from_args;
let command_from_args = common.command_from_args;
let command_capture = common.command_capture;
let command_output_from_args = common.command_output_from_args;

let send_message = transport.send_message;
let edit_message = transport.edit_message;
let send_document = transport.send_document;
let cb_data = transport.cb_data;
let get_file_url = transport.get_file_url;
let tg_request = transport.tg_request;
let is_admin = transport.is_admin;
let get_tg_state = transport.get_tg_state;
let set_tg_state = transport.set_tg_state;
let get_proxy_args = transport.get_proxy_args;
let settings = transport.settings;

let format_bytes = rendering.format_bytes;
let escape_html = rendering.escape_html;
let get_schema_label = rendering.get_schema_label;
let is_boolean_key = rendering.is_boolean_key;
let is_list_key = rendering.is_list_key;
let cidr_match_v4 = rendering.cidr_match_v4;
let build_label = rendering.build_label;
let build_transition = rendering.build_transition;
let build_identity_key = rendering.build_identity_key;
let extract_clean_fptn_token = rendering.extract_clean_fptn_token;
let mask_fptn_token = rendering.mask_fptn_token;
let normalize_mac = rendering.normalize_mac;
let find_mac_block_rules = rendering.find_mac_block_rules;
let valid_updatable_component = rendering.valid_updatable_component;
let safe_allowed_commands_text = rendering.safe_allowed_commands_text;
let safe_execute = rendering.safe_execute;

function get_t() {
    let cfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
    return i18n.bind(cfg.language || "en");
}
let t = function(key, ...args) {
    return get_t()(key, ...args);
};

function view_settings_menu(token, chat_id, msg_id) {
    let text = "⚙️ <b>" + t("menu_all_settings") + "</b>\n\n" + t("menu_choose_cat");
    let keyboard = [
        [{ text: t("menu_global"), callback_data: "/set_cat settings settings" }],
        [{ text: t("menu_telegram"), callback_data: "/set_cat telegram telegram" }],
        [{ text: t("menu_subscriptions"), callback_data: "/set_list subscription_url" }],
        [{ text: t("menu_servers_short"), callback_data: "/set_list server" }],
        [{ text: t("menu_dns_presets"), callback_data: "/dns_presets" }],
        [{ text: t("menu_quiet_hours"), callback_data: "/qh" }],
        [{ text: t("menu_guest"), callback_data: "/guest" }],
        [{ text: t("menu_language"), callback_data: "/lang" }],
        [{ text: t("menu_test_rule"), callback_data: "/test_rule" }],
        [{ text: t("menu_export_config"), callback_data: "/export_config" }],
        [{ text: t("nav_back"), callback_data: "/menu" }]
    ];
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_set_list(token, chat_id, msg_id, stype) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let all = c.get_all(CONFIG_NAME);
    let keyboard = [];
    for (let sname in all) {
        let s = all[sname];
        if (s[".type"] == stype) {
            let label = s.label || s.url || sname;
            if (length(label) > 30) label = substr(label, 0, 30) + "...";
            push(keyboard, [{ text: (s.enabled == "0" ? "❌ " : "✅ ") + label, callback_data: "/set_cat " + stype + " " + sname }]);
        }
    }
    push(keyboard, [{ text: t("menu_categories"), callback_data: "/settings" }]);
    let text = "⚙️ <b>" + stype + "</b>\n" + t("choose_section");
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_set_cat(token, chat_id, msg_id, stype, sname, page) {
    if (!page) page = 0;
    else page = int(page);
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let s = c.get_all(CONFIG_NAME, sname);
    if (!s) return view_settings_menu(token, chat_id, msg_id);
    
    let text = "⚙️ <b>" + t("section_edit") + ":</b> <code>" + escape_html(sname) + "</code> (" + stype + ")\n\n";
    let keyboard = [];
    
    let keys = [];
    // Collect known keys first to keep them at top, then unknowns.
    // Schema keys are listed even when still unset in UCI, otherwise options like
    // daily_report_enabled could never be switched on from the bot.
    if (setting_schema[stype]) {
        for (let k in setting_schema[stype])
            push(keys, k);
    }
    for (let k in s) {
        if (match(k, /^\./)) continue; // ignore .name, .type, .anonymous
        let found = false;
        for (let x in keys) if (x == k) { found = true; break; }
        if (!found) push(keys, k);
    }
    
    let per_page = 14;
    let total = length(keys);
    let start = page * per_page;
    let end = start + per_page;
    if (end > total) end = total;
    
    for (let i = start; i < end; i++) {
        let k = keys[i];
        let label = get_schema_label(stype, k);
        if (is_boolean_key(k)) {
            let b = (s[k] == "1" || s[k] == "true");
            push(keyboard, [{ text: (b ? "✅ " : "❌ ") + label, callback_data: "/set_tog " + stype + " " + sname + " " + k + " " + page }]);
        } else if (is_list_key(k) || type(s[k]) == "array") {
            let cnt = length(common.list_option(s, k));
            push(keyboard, [{ text: "📝 " + label + " (" + cnt + ")", callback_data: "/set_arr " + stype + " " + sname + " " + k }]);
        } else {
            let val = s[k] || "";
            if (length(val) > 15) val = substr(val, 0, 15) + "...";
            push(keyboard, [{ text: "✏️ " + label + ": " + val, callback_data: "/set_str " + stype + " " + sname + " " + k }]);
        }
    }
    
    let nav = [];
    if (start > 0) push(nav, { text: t("nav_prev"), callback_data: "/set_cat " + stype + " " + sname + " " + (page - 1) });
    if (end < total) push(nav, { text: t("nav_next"), callback_data: "/set_cat " + stype + " " + sname + " " + (page + 1) });
    if (length(nav) > 0) push(keyboard, nav);
    
    if (stype == "settings" || stype == "telegram") {
        push(keyboard, [{ text: "🔙 " + t("nav_back"), callback_data: "/settings" }]);
    } else {
        push(keyboard, [{ text: "🔙 " + t("nav_back"), callback_data: "/set_list " + stype }]);
    }
    
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_set_arr(token, chat_id, msg_id, stype, sname, key) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let s = c.get_all(CONFIG_NAME, sname);
    if (!s) return;
    let items = common.list_option(s, key);
    let label = get_schema_label(stype, key);
    
    let text = t("list_header") + " " + escape_html(label) + "\n\n";
    let keyboard = [];
    
    if (length(items) == 0) text += "<i>Пусто</i>\n";
    for (let i = 0; i < length(items); i++) {
        text += "• <code>" + escape_html(items[i]) + "</code>\n";
        if (i < 20) {
            push(keyboard, [{ text: "❌ Удалить " + items[i], callback_data: cb_data(["/set_arr_del", stype, sname, key, items[i]]) }]);
        }
    }
    
    push(keyboard, [{ text: "➕ Добавить элементы", callback_data: "/set_arr_add " + stype + " " + sname + " " + key }]);
    push(keyboard, [{ text: "➖ Очистить список", callback_data: "/set_arr_clr " + stype + " " + sname + " " + key }]);
    push(keyboard, [{ text: "🔙 " + t("nav_back"), callback_data: "/set_cat " + stype + " " + sname }]);
    
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_menu(token, chat_id, msg_id) {
    let sys = api.get_system_status();
    let text = "🏠 <b>Tachyon Control Panel</b>\n\n" +
               t("menu_version") + ": <code>" + sys.tachyon_version + "</code>\n" +
               t("menu_cpu") + ": <code>" + sys.cpu + "</code>\n\n";
               
    let keys_servers = keys(sys.active_servers || {});
    if (length(keys_servers) > 0) {
        text += t("status_active_servers") + "\n";
        for (let i = 0; i < length(keys_servers); i++) {
            let gname = keys_servers[i];
            let srv = sys.active_servers[gname];
            text += "└ " + escape_html(gname) + ": <code>" + escape_html(srv.server) + "</code>\n";
        }
        text += "\n";
    } else {
         text += t("status_no_server") + "\n\n";
    }

    text += t("choose_section");
               
    let keyboard = [
        [
            { text: t("menu_status"), callback_data: "/status" },
            { text: "🔍 Runtime", callback_data: "/runtime" }
        ],
        [
            { text: t("menu_outbounds"), callback_data: "/outbounds" },
            { text: t("menu_sections"), callback_data: "/sections" }
        ],
        [
            { text: t("menu_devices"), callback_data: "/devices" },
            { text: "🐕 Watchdog", callback_data: "/watchdog" }
        ],
        [
            { text: t("menu_speed"), callback_data: "/speed" },
            { text: t("menu_ping"), callback_data: "/ping" }
        ],
        [
            { text: t("menu_diagnostic"), callback_data: "/test" },
            { text: t("menu_connections"), callback_data: "/connections" }
        ],
        [
            { text: t("menu_logs"), callback_data: "/logs" },
            { text: t("menu_info"), callback_data: "/info" }
        ],
        [
            { text: t("menu_heal"), callback_data: "/heal" },
            { text: t("menu_qos"), callback_data: "/qos" }
        ],
        [
            { text: t("menu_all_settings"), callback_data: "/settings" },
            { text: t("menu_help"), callback_data: "/help" }
        ]
    ];

    let has_fptn = false;
    let sections = api.get_sections();
    for (let i = 0; i < length(sections); i++) {
        if (sections[i].action == "fptn") {
            has_fptn = true;
            break;
        }
    }
    if (has_fptn) {
        push(keyboard, [
            { text: "🔑 " + t("fptn_token_btn"), callback_data: "/fptn_token" }
        ]);
    }
    
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_status(token, chat_id, msg_id) {
    let sys = api.get_system_status();
    let conn = api.check_connection();
    let text = "📊 <b>" + t("menu_status") + "</b>\n\n" +
               t("status_version") + ": <code>" + (sys.tachyon_version || "?") + "</code>\n" +
               t("status_uptime") + ": <code>" + sys.uptime + "</code>\n" +
               t("status_cpu") + ": <code>" + sys.cpu + "</code>\n" +
               "RAM: <code>" + sys.ram_avail + "MB / " + sys.ram_total + "MB</code>\n\n" +
               "sing-box: <code>" + sys.singbox + (sys.singbox_variant ? " [" + sys.singbox_variant + "]" : "") + "</code>\n" +
               (sys.zapret2_installed ? "zapret2: <code>" + sys.zapret2 + "</code>\n" : "") +
               "Watchdog: <code>" + (sys.watchdog_running ? "🟢 running" : "🔴 stopped") + "</code>\n\n" +
               "WAN: <code>" + (sys.wan_ip || "?") + "</code> " +
               (conn && conn.direct ? "✅" : "❌") + "\n" +
               "Proxy: " + (conn && conn.proxy ? "✅ reachable" : "❌ unreachable") + "\n" +
               "LAN: <code>" + (sys.lan_ip || "?") + "</code>\n";

    if (sys.pause_remaining > 0) {
        text += "\n" + t("status_pause") + ": " + as_string(sys.pause_remaining) + " sec.\n";
    }

    let keys_servers = keys(sys.active_servers || {});
    if (length(keys_servers) > 0) {
        text += "\n" + t("status_active_servers") + "\n";
        for (let i = 0; i < length(keys_servers); i++) {
            let gname = keys_servers[i];
            let srv = sys.active_servers[gname];
            let lat = srv.latency != "N/A" ? " (" + srv.latency + " ms)" : "";
            text += "└ " + escape_html(gname) + ": <code>" + escape_html(srv.server) + lat + "</code>\n";
        }
    }

    let keyboard = [
        [
            { text: t("menu_speed"), callback_data: "/speed" },
            { text: t("menu_ping"), callback_data: "/ping" }
        ],
        [
            { text: t("btn_refresh"), callback_data: "/status" },
            { text: t("btn_test"), callback_data: "/test" }
        ],
        [{ text: t("nav_back"), callback_data: "/menu" }]
    ];

    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_runtime(token, chat_id, msg_id) {
    let data = api.get_clash_connections();
    let text = "🔍 <b>Runtime Info</b>\n\n";
    if (!data || data.downloadTotal == null) {
        text += t("err_conn_stats");
    } else {
        text += t("stat_download") + ": <code>" + format_bytes(data.downloadTotal) + "</code>\n" +
                t("stat_upload") + ": <code>" + format_bytes(data.uploadTotal) + "</code>\n" +
                t("stat_memory") + ": <code>" + format_bytes(data.memory) + "</code>\n" +
                t("stat_connections") + ": <code>" + length(data.connections || []) + "</code>\n";
    }
    
    let keyboard = [
        [{ text: t("btn_refresh"), callback_data: "/runtime" }],
        [{ text: t("nav_back"), callback_data: "/menu" }]
    ];
    
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_outbounds(token, chat_id, msg_id, group_name) {
    let data = api.get_clash_proxies_data();
    if (!data || !data.proxies) {
        let err = t("err_servers_list");
        if (msg_id) edit_message(token, chat_id, msg_id, err, "HTML", [[{text:t("nav_back"), callback_data:"/menu"}]]);
        else send_message(token, chat_id, err, "HTML", [[{text:t("nav_back"), callback_data:"/menu"}]]);
        return;
    }
    
    let groups = [];
    for (let gname in keys(data.proxies)) {
        let p = data.proxies[gname];
        if (p.type == "Selector" || p.type == "URLTest" || p.type == "Fallback") {
            push(groups, gname);
        }
    }
    
    if (length(groups) == 0) {
        let err = "❌ " + t("outbound_groups_not_found");
        if (msg_id) edit_message(token, chat_id, msg_id, err, "HTML", [[{text:"⬅️ " + t("nav_back"), callback_data:"/menu"}]]);
        else send_message(token, chat_id, err, "HTML", [[{text:"⬅️ " + t("nav_back"), callback_data:"/menu"}]]);
        return;
    }
    
    if (length(groups) == 1 && !group_name) {
        group_name = groups[0];
    }
    
    let text = "🌐 <b>" + t("menu_outbounds") + "</b>\n\n";
    let keyboard = [];
    
    if (!group_name) {
        text += t("section_choose_group");
        for (let i = 0; i < length(groups); i++) {
            let gname = groups[i];
            let active = data.proxies[gname].now || "none";
            text += "• <b>" + escape_html(gname) + "</b>: <code>" + escape_html(active) + "</code>\n";
            push(keyboard, [{ text: "🌐 " + gname, callback_data: "/outbounds " + gname }]);
        }
        push(keyboard, [{ text: t("btn_refresh"), callback_data: "/outbounds" }]);
        push(keyboard, [{ text: t("nav_back"), callback_data: "/menu" }]);
    } else {
        let group_data = data.proxies[group_name];
        if (!group_data) return view_outbounds(token, chat_id, msg_id);
        
        text += t("section_group") + ": <b>" + escape_html(group_name) + "</b>\n\n";
        let active_server = group_data.now || "";
        
        let row = [];
        let count = 0;
        let servers = group_data.all || [];
        
        for (let i = 0; i < length(servers); i++) {
            let name = servers[i];
            let proxy = data.proxies[name];
            let delay = "N/A";
            if (proxy) {
                if (type(proxy.history) == "array" && length(proxy.history) > 0) {
                    let last = proxy.history[length(proxy.history) - 1];
                    if (last && last.delay) delay = last.delay + " ms";
                }
            }
            let marker = (name == active_server) ? "🔵" : "•";
            text += marker + " <code>" + escape_html(name) + "</code>: <code>" + delay + "</code>\n";

            if (count < 18) {
                push(row, { text: (name == active_server ? "🔵 " : "") + name, callback_data: cb_data([ "/sw", group_name, name ]) });
                if (length(row) == 2) {
                    push(keyboard, row);
                    row = [];
                }
                count++;
            }
        }
        if (length(row) > 0) push(keyboard, row);
        
        if (count == 0) text += "<i>" + t("servers_not_found") + "</i>\n";
        else text += "\nℹ️ " + t("outbounds_hint");
        
        push(keyboard, [{ text: t("btn_refresh"), callback_data: "/outbounds " + group_name }]);
        if (length(groups) > 1) {
            push(keyboard, [{ text: t("btn_back_to_groups"), callback_data: "/outbounds" }]);
        } else {
            push(keyboard, [{ text: t("nav_back"), callback_data: "/menu" }]);
        }
    }
    
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function save_persistent_selector_choice(group_tag, proxy_tag) {
    group_tag = as_string(group_tag);
    proxy_tag = as_string(proxy_tag);
    if (group_tag == "" || proxy_tag == "")
        return false;
    let path = getenv("TACHYON_PERSISTENT_SELECTOR_STATE_FILE") || "/etc/tachyon/selector_state.json";
    let state = common.read_json_file(path);
    if (type(state) != "object")
        state = {};
    state[group_tag] = proxy_tag;
    return common.write_json_file(path, state, 2);
}

function view_sections(token, chat_id, msg_id) {
    let sections = api.get_sections();
    let text = "⚙️ <b>" + t("menu_sections") + "</b>\n\n";
    let keyboard = [];
    
    for (let s in sections) {
        let label = s.label || s.name || s[".name"];
        let status = (s.enabled == "1") ? "✅" : "❌";
        push(keyboard, [{ text: status + " " + label, callback_data: "/sec_view " + s[".name"] }]);
    }
    
    push(keyboard, [{ text: t("section_create"), callback_data: "/sec_create" }]);
    push(keyboard, [{ text: t("nav_back"), callback_data: "/menu" }]);
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_section_editor(token, chat_id, msg_id, sec_name) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let s = c.get_all(CONFIG_NAME, sec_name);
    if (!s) return view_sections(token, chat_id, msg_id);
    
    let status = (s.enabled == "1") ? t("status_enabled") : t("status_disabled");
    let text = "⚙️ <b>" + t("section_section") + ":</b> " + escape_html(s.label || s.name || sec_name) + "\n" +
               t("section_type") + ": <code>" + escape_html(s.action || "none") + "</code>\n" +
               t("section_status") + ": <b>" + status + "</b>\n\n";
               
    if (s.action == "proxy" || s.action == "route") {
        text += t("status_target") + ": <code>" + escape_html(s.target || "main-out") + "</code>\n";
    }
    if (s.action == "fptn") {
        let tok = s.access_token || "";
        text += "🔑 Token: <code>" + escape_html(mask_fptn_token(tok)) + "</code>\n";
    }
    
    let d_count = length(common.list_option(s, "domain")) + length(common.list_option(s, "domain_suffix")) + length(common.list_option(s, "domain_keyword")) + length(common.list_option(s, "domain_regex"));
    let ip_count = length(common.list_option(s, "ip")) + length(common.list_option(s, "ip_cidr"));
    let src_count = length(common.list_option(s, "src_ip")) + length(common.list_option(s, "src_mac")) + length(common.list_option(s, "src_device"));
    let rs_count = length(common.list_option(s, "community_lists"));

    let sub_count = 0;
    let all = c.get_all(CONFIG_NAME);
    for (let sname in all) {
        if (all[sname][".type"] == "subscription_url" && all[sname].section == sec_name) sub_count++;
    }
               
    let keyboard = [];
    push(keyboard, [
        { text: (s.enabled == "1" ? "🔴 " + t("status_disabled") : "🟢 " + t("status_enabled")), callback_data: "/sec_toggle " + sec_name },
        { text: t("btn_rename"), callback_data: "/sec_rename " + sec_name }
    ]);
    
    push(keyboard, [{ text: t("section_action") + ": " + (s.action || "none"), callback_data: "/sec_action " + sec_name }]);
    if (s.action == "proxy" || s.action == "route") {
        push(keyboard, [{ text: t("status_target") + ": " + (s.target || "main-out"), callback_data: "/sec_target " + sec_name }]);
    }
    if (s.action == "fptn") {
        push(keyboard, [{ text: "🔑 " + t("fptn_token_change_btn"), callback_data: "/fptn_token " + sec_name }]);
    }
    
    push(keyboard, [
        { text: t("section_domains") + " (" + d_count + ")", callback_data: "/sec_list " + sec_name + " domain" },
        { text: "📝 IP (" + ip_count + ")", callback_data: "/sec_list " + sec_name + " ip" }
    ]);
    push(keyboard, [
        { text: t("section_sources") + " (" + src_count + ")", callback_data: "/sec_list " + sec_name + " src" },
        { text: "📝 Rulesets (" + rs_count + ")", callback_data: "/sec_list " + sec_name + " ruleset" }
    ]);

    push(keyboard, [{ text: t("menu_subscriptions") + " (" + sub_count + ")", callback_data: "/sec_subs " + sec_name }]);
    
    push(keyboard, [{ text: t("btn_delete_section"), callback_data: "/sec_delete " + sec_name }]);
    push(keyboard, [{ text: t("btn_back_to_sections"), callback_data: "/sections" }]);
    
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_sec_list(token, chat_id, msg_id, sec_name, list_type) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let s = c.get_all(CONFIG_NAME, sec_name);
    if (!s) return;
    
    let items = [];
    let title = "";
    if (list_type == "domain") {
        title = t("section_domains");
        let ds = common.list_option(s, "domain_suffix");
        for (let x in ds) push(items, {type: "domain_suffix", val: x});
        let d = common.list_option(s, "domain");
        for (let x in d) push(items, {type: "domain", val: x});
        let dk = common.list_option(s, "domain_keyword");
        for (let x in dk) push(items, {type: "domain_keyword", val: x});
        let dr = common.list_option(s, "domain_regex");
        for (let x in dr) push(items, {type: "domain_regex", val: x});
    } else if (list_type == "ip") {
        title = t("section_ips");
        let ipc = common.list_option(s, "ip_cidr");
        for (let x in ipc) push(items, {type: "ip_cidr", val: x});
        let ip = common.list_option(s, "ip");
        for (let x in ip) push(items, {type: "ip", val: x});
    } else if (list_type == "src") {
        title = t("section_sources");
        let sdev = common.list_option(s, "src_device");
        for (let x in sdev) push(items, {type: "src_device", val: x});
        let sip = common.list_option(s, "src_ip");
        for (let x in sip) push(items, {type: "src_ip", val: x});
        let smac = common.list_option(s, "src_mac");
        for (let x in smac) push(items, {type: "src_mac", val: x});
    } else if (list_type == "ruleset") {
        title = "Rulesets";
        let rs = common.list_option(s, "community_lists");
        for (let x in rs) push(items, {type: "community_lists", val: x});
    }
    
    let text = t("section_list_header") + " " + escape_html(s.label || s.name || sec_name) + "\n" +
               "📋 <b>" + title + "</b>:\n\n";
               
    let keyboard = [];
    if (length(items) == 0) {
        text += "<i>Пусто.</i>\n";
    } else {
        for (let i = 0; i < length(items); i++) {
            let it = items[i];
            text += "• <code>" + escape_html(it.val) + "</code> (" + it.type + ")\n";
            // Add individual delete buttons (up to 20 for UI limits)
            if (i < 20) {
                push(keyboard, [{ text: "❌ Удалить " + it.val, callback_data: cb_data(["/sec_del_it", sec_name, it.type, it.val]) }]);
            }
        }
        if (length(items) > 20) text += "\n<i>(Показаны не все элементы для удаления)</i>\n";
    }
    
    push(keyboard, [
        { text: "➕ Добавить", callback_data: "/sec_add " + sec_name + " " + list_type },
        { text: "➖ Очистить все", callback_data: "/sec_clear " + sec_name + " " + list_type }
    ]);
    push(keyboard, [{ text: "🔙 " + t("btn_back_to_section"), callback_data: "/sec_view " + sec_name }]);
    
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function exec_doctor(token, chat_id) {
    send_message(token, chat_id, "⏳ <b>" + t("diag_starting") + "</b>", "HTML");
    let res = command_capture(command_from_args([ "/usr/bin/tachyon", "doctor" ]));
    let report = res ? (res.output || t("diag_no_output")) : t("diag_error");

    let data = null;
    try { data = json(report); } catch (e) {}
    if (data != null && type(data) == "object") {
        let text = trim(as_string(data.report || ""));
        if (text == "") {
            report = t("diag_empty");
        } else {
            let header;
            if (data.busy) {
                header = t("diag_running");
            } else if (int(data.issues || 0) > 0) {
                header = sprintf(t("diag_issues_count"), as_string(data.issues));
                if (int(data.fixed || 0) > 0)
                    header += sprintf(t("diag_fixed_count"), as_string(data.fixed));
                let planned = length(data.planned_fixes || []);
                if (planned > 0)
                    header += sprintf(t("diag_planned_count"), planned);
            } else {
                header = t("diag_clean");
            }
            report = "<b>" + escape_html(header) + "</b>\n\n<pre>" + escape_html(text) + "</pre>";
            if (length(report) > 3900)
                report = substr(report, 0, 3900) + "\n... (" + t("report_truncated") + ")";
            send_message(token, chat_id, report, "HTML", [[{text:t("nav_back"), callback_data:"/menu"}]]);
            return;
        }
    }

    if (length(report) > 3500) report = substr(report, 0, 3500) + "\n... (" + t("report_truncated") + ")";
    send_message(token, chat_id, "🩺 <b>" + t("diag_results") + "</b>\n\n<pre>" + escape_html(report) + "</pre>", "HTML", [[{text:t("nav_back"), callback_data:"/menu"}]]);
}

function exec_restart(token, chat_id) {
    let text = t("restart_confirm");
    let keyboard = [
        [{ text: t("restart_yes"), callback_data: "/confirm_restart" }],
        [{ text: t("nav_cancel"), callback_data: "/menu" }]
    ];
    send_message(token, chat_id, text, "HTML", keyboard);
}

function restore_config_from_backup(backup_path) {
    if (backup_path && fs.stat(backup_path)) {
        let tmp = "/etc/config/tachyon.restore-tmp";
        system(command_from_args([ "cp", "-a", backup_path, tmp ]) + " >/dev/null 2>&1");
        system(command_from_args([ "mv", "-f", tmp, "/etc/config/tachyon" ]) + " >/dev/null 2>&1");
    }
}

function exec_backup(token, chat_id) {
    send_message(token, chat_id, "⏳ <b>" + t("backup_collecting") + "</b>", "HTML");
    let file_path = "/etc/.tachyon/backup.tar.gz";
    command_status(command_from_args([ "tar", "-czf", file_path, "-C", "/etc", "config/tachyon", "tachyon" ]) + " 2>/dev/null");

    if (fs.stat(file_path)) {
        send_document(token, chat_id, file_path);
        fs.unlink(file_path);
    } else {
        send_message(token, chat_id, "❌ <b>" + t("backup_create_error") + "</b>", "HTML", [[{text:"⬅️ " + t("nav_menu"), callback_data:"/menu"}]]);
    }
}

function exec_support_bundle(token, chat_id) {
    send_message(token, chat_id, "⏳ <b>" + t("support_bundle_collecting") + "</b>", "HTML");
    system(command_from_args([ "ip", "route" ]) + " > /etc/.tachyon/ip_route.txt");
    system(command_from_args([ "logread" ]) + " > /etc/.tachyon/logread.txt");
    let file_path = "/etc/.tachyon/support_bundle.tar.gz";
    command_status(command_from_args([ "tar", "-czf", file_path, "/etc/config/tachyon", "/var/etc/tachyon", "/etc/config/network", "/etc/config/firewall", "/tmp/dhcp.leases", "/etc/.tachyon/ip_route.txt", "/etc/.tachyon/logread.txt" ]) + " 2>/dev/null");
    
    if (fs.stat(file_path)) {
        send_document(token, chat_id, file_path);
        fs.unlink(file_path);
    } else {
        send_message(token, chat_id, "❌ <b>" + t("support_bundle_error") + "</b>", "HTML");
    }
    // Absent file already satisfies the caller; fs.unlink throws on ENOENT.
    try { fs.unlink("/etc/.tachyon/ip_route.txt"); fs.unlink("/etc/.tachyon/logread.txt"); } catch(e) {}
}

function exec_close_connections(token, chat_id) {
    let out = api.clash_request("DELETE", "connections", null);
    if (out != null)
        send_message(token, chat_id, "✅ <b>" + t("conn_closed_msg") + "</b>", "HTML", [[{text:"⬅️ " + t("nav_menu"), callback_data:"/menu"}]]);
    else
        send_message(token, chat_id, "❌ <b>" + t("conn_close_error") + "</b>", "HTML", [[{text:"⬅️ " + t("nav_menu"), callback_data:"/menu"}]]);
}

function exec_check_updates(token, chat_id, msg_id) {
    let out = command_output_from_args(["/usr/bin/tachyon", "component_update_check_cache"]);
    let text = "📦 <b>" + t("updates_title") + "</b>\n\n";
    let keyboard = [];
    if (out && out != "") {
        try {
            let data = json(out);
            let results = data.results || [];
            let has_updates = false;
            if (!data.enabled) {
                text += t("updates_disabled");
            } else if (length(results) == 0) {
                text += t("updates_cache_empty");
            } else {
                for (let comp in results) {
                    let name = comp.component || "";
                    let title = (name == "sing_box") ? "sing-box" : name;
                    let cur = comp.current_version || "?";
                    let lat = comp.latest_version || "?";
                    if (!comp.success) {
                        text += "• <b>" + title + "</b>: ❌ Ошибка проверки\n";
                    } else if (comp.status == "outdated_same_release") {
                        let transition = build_transition(comp);
                        text += "• <b>" + title + "</b>: <code>" + cur + "</code> — " + t("update_new_release_build") +
                            (transition != "" ? " " + transition : "") + " ⚠️\n";
                        push(keyboard, [{text: t("btn_update_component") + " " + title, callback_data: "/update_component " + name}]);
                        has_updates = true;
                    } else if (comp.status == "outdated") {
                        text += "• <b>" + title + "</b>: <code>" + cur + "</code> ➡️ <code>" + lat + "</code> ⚠️\n";
                        push(keyboard, [{text: t("btn_update_component") + " " + title, callback_data: "/update_component " + name}]);
                        has_updates = true;
                    } else if (comp.status == "dev") {
                        text += "• <b>" + title + "</b>: <code>" + cur + "</code> 🧪 " + t("update_dev_build") + "\n";
                    } else {
                        text += "• <b>" + title + "</b>: <code>" + cur + "</code> ✅\n";
                    }
                }
                if (!has_updates) text += "\n✅ " + t("update_all_current");
            }
        } catch(e) {
            text += "❌ " + t("update_cache_parse_error") + " " + e;
        }
    } else {
        text += t("update_cache_unavailable");
    }
    
    push(keyboard, [{ text: t("btn_refresh_cache"), callback_data: "/check_updates" }]);
    push(keyboard, [{ text: "⬅️ " + t("nav_back"), callback_data: "/menu" }]);
    
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_instances(token, chat_id, msg_id) {
    let data = api.get_clash_proxies_data();
    let text = "🖧 <b>Live Server Instances</b>\n\n";
    if (data && data.proxies) {
        try {
            let proxies = data.proxies;
            let count = 0;
            for (let name in proxies) {
                let p = proxies[name];
                if (p.type == "Selector" || p.type == "URLTest" || p.type == "Direct" || p.type == "Reject" || p.type == "Compatible") continue;
                let delay = "➖";
                if (p.history && length(p.history) > 0) {
                    let last = p.history[length(p.history) - 1];
                    if (last.delay > 0) delay = last.delay + " ms";
                    else delay = "❌ Timeout";
                }
                text += "• <code>" + escape_html(name) + "</code> (" + p.type + "): <b>" + delay + "</b>\n";
                count++;
            }
            if (count == 0) text += t("servers_none");
        } catch(e) {
            text += t("api_parse_error") + " " + e;
        }
    } else {
        text += "❌ " + t("api_connect_failed");
    }
    
    let kb = [[
        {text: "🔄 " + t("btn_refresh"), callback_data: "/instances"},
        {text: "⬅️ " + t("nav_back"), callback_data: "/status"}
    ]];
    
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", kb);
    else send_message(token, chat_id, text, "HTML", kb);
}

function exec_speedtest(token, chat_id, msg_id) {
    let wait_text = t("speed_starting");
    if (msg_id) edit_message(token, chat_id, msg_id, wait_text, "HTML");
    else send_message(token, chat_id, wait_text, "HTML");

    let result = api.run_speedtest();
    let text = "⚡ <b>" + t("speed_result") + "</b>\n\n";
    if (result) {
        text += t("speed_direct") + " " +
            (result.direct_mbps > 0
                ? "<code>" + sprintf("%.1f", result.direct_mbps) + " Mbps</code>\n"
                : t("speed_fail_measure") + "\n");
        text += t("speed_proxy") + " " +
            (result.proxy_mbps > 0
                ? "<code>" + sprintf("%.1f", result.proxy_mbps) + " Mbps</code>\n"
                : t("speed_fail_measure") + "\n");
        if (result.direct_mbps <= 0 && result.proxy_mbps <= 0)
            text += "\n<i>" + t("speed_check_hint") + "</i>\n";
    } else {
        text += t("speed_error") + "\n";
    }

    let keyboard = [
        [{ text: t("btn_speed_again"), callback_data: "/speed" }],
        [{ text: t("nav_back"), callback_data: "/status" }]
    ];
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_ping(token, chat_id, msg_id) {
    let text = "📍 <b>" + t("menu_ping") + "</b>\n\n";
    let data = api.get_clash_proxies_data();
    if (!data || !data.proxies) {
        text += t("ping_api_error");
        let keyboard = [[{ text: t("btn_refresh"), callback_data: "/ping" }, { text: t("nav_back"), callback_data: "/status" }]];
        if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
        else send_message(token, chat_id, text, "HTML", keyboard);
        return;
    }

    let shown = 0;
    for (let name in data.proxies) {
        let p = data.proxies[name];
        if (p.type != "Selector" && p.type != "URLTest") continue;
        if (!p.history || length(p.history) == 0) continue;
        let last = p.history[length(p.history) - 1];
        if (!last || !last.delay) continue;
        let delay = int(last.delay);
        let icon = delay < 100 ? "🟢" : (delay < 300 ? "🟡" : "🔴");
        text += icon + " <code>" + escape_html(name) + "</code>: <code>" + delay + " ms</code>\n";
        shown++;
    }
    if (shown == 0) text += t("latency_no_data");

    let keyboard = [
        [{ text: "🔄 " + t("btn_refresh"), callback_data: "/ping" }],
        [{ text: "⬅️ " + t("nav_back"), callback_data: "/status" }]
    ];
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_quick_test(token, chat_id, msg_id) {
    let text = "🩺 <b>" + t("test_title") + "</b>\n\n";
    let conn = api.check_connection();
    let sys = api.get_system_status();

    text += (conn && conn.direct ? "✅" : "❌") + " " + t("test_direct") + "\n";
    text += (conn && conn.proxy ? "✅" : "❌") + " " + t("test_proxy") + "\n";
    text += (sys && sys.singbox_running ? "✅" : "❌") + " sing-box\n";
    text += (sys && sys.tachyon_running ? "✅" : "❌") + " " + t("test_service") + "\n";
    text += (sys && sys.watchdog_running ? "✅" : "❌") + " Watchdog\n";

    let nft = command_capture(command_from_args(["/usr/sbin/nft", "list", "tables"]));
    text += (nft && nft.status == 0 && match(nft.output || "", /TachyonTable/)) ? "✅" : "❌";
    text += " " + t("test_nft") + "\n";

    let dns_ok = false;
    try {
        let dns_res = command_capture(command_from_args(["nslookup", "google.com", "127.0.0.1"]));
        dns_ok = dns_res && dns_res.status == 0;
    }
    catch (e) {
    }
    text += (dns_ok ? "✅" : "❌") + " DNS\n";

    if (sys && sys.pause_remaining > 0) {
        text += "\n⏸ " + t("test_pause") + " " + as_string(sys.pause_remaining) + " sec.";
    }

    let keyboard = [
        [{ text: t("btn_retry"), callback_data: "/test" }],
        [{ text: t("nav_back"), callback_data: "/menu" }]
    ];
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_logs(token, chat_id, msg_id, level, count) {
    level = level || "all";
    count = int(count || "30");

    let text = "📋 <b>" + t("logs_header") + "</b> (" + t("logs_level") + ": " + level + ", " + count + ")\n\n<pre>";

    let args = ["/sbin/logread"];
    let res = command_capture(command_from_args(args));
    if (res && res.status == 0 && res.output) {
        let lines = split(res.output, "\n");
        let filtered = [];
        let udp_http_notice_emitted = false;
        for (let line in lines) {
            if (line == "") continue;
            if (index(as_string(line), "UDP is not supported by outbound:") >= 0) {
                if (!udp_http_notice_emitted) {
                    push(filtered, "UDP traffic through HTTP outbounds is not supported by sing-box; repeated UDP warnings for HTTP outbounds are hidden by Tachyon.");
                    udp_http_notice_emitted = true;
                }
                continue;
            }
            if (level == "error" && !match(line, /\[err\]|\[error\]/i)) continue;
            if (level == "warn" && !match(line, /\[warn\]/i)) continue;
            if (level == "info" && !match(line, /\[info\]/i)) continue;
            if (match(line, /tachyon|sing-box|watchdog/i)) push(filtered, line);
        }
        let start = length(filtered) - count;
        if (start < 0) start = 0;
        for (let i = start; i < length(filtered); i++) {
            text += escape_html(filtered[i]) + "\n";
        }
        if (length(filtered) == 0) text += t("logs_no_records");
    } else {
        text += t("logs_read_error");
    }
    text += "</pre>";

    let keyboard = [
        [
            { text: "❌ Errors", callback_data: "/logs error 30" },
            { text: "⚠️ Warns", callback_data: "/logs warn 30" }
        ],
        [
            { text: "ℹ️ Info", callback_data: "/logs info 30" },
            { text: "📋 All", callback_data: "/logs all 30" }
        ],
        [{ text: "🔄 " + t("btn_refresh"), callback_data: "/logs " + level + " " + as_string(count) }],
        [{ text: "⬅️ " + t("nav_back"), callback_data: "/menu" }]
    ];
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_system_info(token, chat_id, msg_id) {
    let text = "ℹ️ <b>" + t("info_title") + "</b>\n\n";
    let res = command_capture(command_from_args([BIN_PATH, "get_system_info"]));
    if (res && res.status == 0 && res.output) {
        try {
            let info = json(res.output);
            text += "📱 " + t("info_device_label") + ": <code>" + as_string(info.device_model || "N/A") + "</code>\n";
            text += "💻 OpenWrt: <code>" + as_string(info.openwrt_version || "N/A") + "</code>\n\n";
            text += "🔧 Tachyon: <code>" + as_string(info.tachyon_version || "N/A") + "</code>\n";
            text += "📱 LuCI App: <code>" + as_string(info.luci_app_version || "N/A") + "</code>\n\n";
            text += "📦 sing-box: <code>" + as_string(info.sing_box_version || "N/A") + "</code>\n";
            if (info.sing_box_lx == 1) text += "   Fork: Leadaxe (lx) 🟢\n";
            else if (info.sing_box_compressed == 1) text += "   Fork: Extended (compressed) 🔵\n";
            else if (info.sing_box_extended == 1) text += "   Fork: Extended (shtorm-7) 🔵\n";
            else if (info.sing_box_tiny == 1) text += "   Variant: Tiny 🟡\n";
            else text += "   Variant: Official / Stock ⚪\n";
            if (info.sing_box_tailscale == 1) text += "   Tailscale: ✅\n";
            text += "\n";
            if (info.zapret_installed == "1") text += "🛡 Zapret: <code>" + as_string(info.zapret_version || "?") + "</code>\n";
            if (info.zapret2_installed == "1") text += "🛡 Zapret2: <code>" + as_string(info.zapret2_version || "?") + "</code>\n";
            if (info.byedpi_installed == "1") text += "🛡 ByeDPI: <code>" + as_string(info.byedpi_version || "?") + "</code>\n";
            if (info.wdtt_installed == "1") text += "🛡 WDTT: <code>" + as_string(info.wdtt_version || "?") + "</code>\n";
            if (info.olcrtc_installed == "1") text += "🛡 OlcRTC: <code>" + as_string(info.olcrtc_version || "?") + "</code>\n";
        } catch(e) {
            text += t("info_read_error") + " " + e;
        }
    } else {
        text += "❌ " + t("info_fetch_failed");
    }

    let keyboard = [
        [{ text: "🔄 " + t("btn_refresh"), callback_data: "/info" }],
        [{ text: "⬅️ " + t("nav_back"), callback_data: "/menu" }]
    ];
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_connections(token, chat_id, msg_id, page) {
    page = int(page || 0);
    if (page < 0) page = 0;
    let data = api.get_clash_connections();
    let text = "🔗 <b>" + t("menu_connections") + "</b>\n\n";

    if (!data || !data.connections || length(data.connections) == 0) {
        text += t("conn_none");
        let keyboard = [
            [{ text: t("btn_refresh"), callback_data: "/connections" }],
            [{ text: t("nav_back"), callback_data: "/menu" }]
        ];
        if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
        else send_message(token, chat_id, text, "HTML", keyboard);
        return;
    }

    text += t("conn_total_down") + ": <code>" + format_bytes(data.downloadTotal) + "</code>\n";
    text += t("conn_total_up") + ": <code>" + format_bytes(data.uploadTotal) + "</code>\n";
    text += t("stat_connections") + ": <code>" + length(data.connections) + "</code>\n\n";

    let per_page = 8;
    let total = length(data.connections);
    let start = page * per_page;
    let end = start + per_page;
    if (end > total) end = total;

    for (let i = start; i < end; i++) {
        let c = data.connections[i];
        let metadata = c.metadata || {};
        let proto = metadata.type || "?";
        let dest = metadata.destinationIP || "?";
        let local = metadata.sourceIP || "?";
        let chain = "";
        if (c.chain && length(c.chain) > 0) chain = c.chain[length(c.chain) - 1];
        let dl = format_bytes(c.download);
        let ul = format_bytes(c.upload);
        text += "• <code>" + escape_html(proto) + "</code> " + escape_html(local) + " → " + escape_html(dest) + "\n";
        text += "  ↳ " + escape_html(chain) + "  📥" + dl + " 📤" + ul + "\n";
    }

    let total_pages = int((total + per_page - 1) / per_page);
    let keyboard = [];
    if (total_pages > 1) {
        let nav = [];
        if (page > 0) push(nav, { text: "◀️ Prev", callback_data: "/connections " + as_string(page - 1) });
        push(nav, { text: as_string(page + 1) + "/" + as_string(int(total_pages)), callback_data: "/noop" });
        if (end < total) push(nav, { text: "▶️ Next", callback_data: "/connections " + as_string(page + 1) });
        push(keyboard, nav);
    }
    push(keyboard, [{ text: t("btn_refresh"), callback_data: "/connections" }]);
    push(keyboard, [{ text: t("btn_close_all"), callback_data: "/close_connections" }]);
    push(keyboard, [{ text: "⬅️ " + t("nav_back"), callback_data: "/menu" }]);

    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_sec_subs(token, chat_id, msg_id, sec_name) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let all = c.get_all(CONFIG_NAME);
    let keyboard = [];
    let count = 0;
    let idx = 0;
    for (let sname in all) {
        let s = all[sname];
        if (s[".type"] == "subscription_url" && s.section == sec_name) {
            let url = s.url || t("sub_empty_url");
            if (length(url) > 35) url = substr(url, 0, 35) + "...";
            let icon = s.enabled == "0" ? "❌" : "✅";
            push(keyboard, [{ text: icon + " " + url, callback_data: "/set_cat subscription_url " + sname }]);
            push(keyboard, [{ text: "   🗑 Удалить", callback_data: "/sec_sub_del " + sec_name + " " + idx }]);
            count++;
        }
        idx++;
    }
    push(keyboard, [{ text: "➕ Добавить подписку", callback_data: "/sec_sub_add " + sec_name }]);
    push(keyboard, [{ text: "🔙 " + t("nav_back"), callback_data: "/sec_view " + sec_name }]);
    let text = "🔗 <b>" + t("sub_section_subs") + " " + escape_html(sec_name) + "</b>\n\n";
    if (count == 0) {
        text += t("sub_none");
    } else {
        text += t("sub_found_count") + " " + count;
    }
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_help(token, chat_id, msg_id) {
    let text = "📖 <b>" + t("help_title") + "</b>\n\n" +
        "<b>" + t("help_main_section") + "</b>\n" +
        "/status — Статус системы\n" +
        "/runtime — Статистика трафика\n" +
        "/outbounds — Прокси серверы\n" +
        "/sections — Секции маршрутизации\n" +
        "/devices — Устройства в сети\n" +
        "/instances — Live серверы\n\n" +
        "<b>" + t("help_diag_section") + "</b>\n" +
        "/speed — Тест скорости\n" +
        "/ping — Задержка до серверов\n" +
        "/test — Быстрая диагностика\n" +
        "/doctor — Полная диагностика\n" +
        "/logs — Просмотр логов\n" +
        "/info — Информация о системе\n" +
        "/connections — Активные подключения\n\n" +
        "<b>" + t("help_manage_section") + "</b>\n" +
        "/restart — Перезапуск служб Tachyon\n" +
        "/backup — Бэкап конфига\n" +
        "/close_connections — Закрыть все соединения\n" +
        "/check_updates — Проверить обновления\n\n" +
        "<b>" + t("help_settings_section") + "</b>\n" +
        "/settings — Все настройки\n" +
        "/dns_presets — DNS пресеты\n" +
        "/help — " + t("help_this");

    let keyboard = [[{ text: "⬅️ " + t("nav_menu"), callback_data: "/menu" }]];
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_language(token, chat_id, msg_id) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let current_lang = option(c.get_all(CONFIG_NAME, "telegram"), "language", "en");
    let langs = i18n.available_languages(current_lang);
    let lang_label = (current_lang == "ru") ? "Русский" : "English";

    let text = t("choose_language") + "\n\n" + t("lang_current", lang_label);
    let keyboard = [];
    let row = [];
    for (let i = 0; i < length(langs); i++) {
        let l = langs[i];
        let marker = (l.code == current_lang) ? " ✅" : "";
        push(row, { text: l.label + marker, callback_data: "/lang_set " + l.code });
        if (length(row) == 2) { push(keyboard, row); row = []; }
    }
    if (length(row) > 0) push(keyboard, row);
    push(keyboard, [{ text: t("nav_back"), callback_data: "/settings" }]);

    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_guest_mode(token, chat_id, msg_id) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let s = object_or_empty(c.get_all(CONFIG_NAME, "guest_mode"));
    let enabled = bool_option(s, "enabled", false);
    let gmode = option(s, "mode", "selected");
    let mode_label = (gmode == "inverted") ? t("guest_mode_inverted") : t("guest_mode_selected");
    let guest_devs = list_option(s, "guest_devices");
    let trusted_devs = list_option(s, "trusted_devices");
    let time_limit = int_option(s, "daily_time_limit", 0);
    let traffic_limit = int_option(s, "daily_traffic_limit", 0);
    let isolate_lan = bool_option(s, "isolate_lan", true);

    let text = "👥 <b>" + t("guest_title") + "</b>\n\n" +
        (enabled ? t("guest_status_active") : t("guest_status_inactive")) + "\n" +
        "📋 " + t("routing_mode") + ": <b>" + mode_label + "</b>\n";

    if (gmode == "inverted") {
        text += sprintf(t("guest_trusted_count"), length(trusted_devs)) + "\n";
    } else {
        text += sprintf(t("guest_devices_count"), length(guest_devs)) + "\n";
    }

    if (isolate_lan) {
        text += "🛡 " + t("guest_lan_isolated") + "\n";
    }

    if (time_limit > 0) {
        text += sprintf(t("guest_time_limit"), time_limit) + "\n";
    }
    if (traffic_limit > 0) {
        text += sprintf(t("guest_traffic_limit"), as_string(traffic_limit) + " MB") + "\n";
    }

    let quota_state = fs.readfile("/var/run/tachyon/parental_quotas.json");
    if (quota_state) {
        try {
            let q = json(quota_state);
            let devs = object_or_empty(q.devices);
            let active_guests = [];
            for (let ident in keys(devs)) {
                let dev_entry = devs[ident];
                if (dev_entry.is_guest || dev_entry.blocked) {
                    let st = dev_entry.blocked ? "🚫" : "⏳";
                    let info = st + " <code>" + ident + "</code>: " + as_string(dev_entry.minutes || 0) + " мин";
                    if (dev_entry.bytes) info += " (" + format_bytes(dev_entry.bytes) + ")";
                    push(active_guests, info);
                }
            }
            if (length(active_guests) > 0) {
                text += "\n<b>Активность сегодня:</b>\n" + join("\n", active_guests) + "\n";
            }
        } catch(e) {}
    }

    let toggle_label = enabled ? ("🔴 " + t("btn_disable")) : ("🟢 " + t("btn_enable"));
    let keyboard = [
        [{ text: toggle_label, callback_data: "/guest_toggle" }],
        [{ text: t("nav_back"), callback_data: "/settings" }]
    ];
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_quiet_hours(token, chat_id, msg_id) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let s = c.get_all(CONFIG_NAME, "telegram");
    let enabled = option(s, "quiet_hours_enabled", "0") == "1";
    let start_hr = option(s, "quiet_hours_start", "23");
    let end_hr = option(s, "quiet_hours_end", "7");

    let text = "🔕 <b>" + t("quiet_hours_title") + "</b>\n\n" +
        t("quiet_status") + ": " + (enabled ? "🟢 " + t("quiet_enabled_label") : "❌ " + t("quiet_disabled_label")) + "\n" +
        t("quiet_start_label") + " <code>" + start_hr + ":00</code>\n" +
        t("quiet_end_label") + " <code>" + end_hr + ":00</code>\n\n" +
        t("quiet_hint");

    let keyboard = [
        [{ text: (enabled ? t("btn_disable") : t("btn_enable")), callback_data: "/qh_toggle" }],
        [{ text: "⏰ Начало: " + start_hr, callback_data: "/qh_start" }],
        [{ text: "⏰ Конец: " + end_hr, callback_data: "/qh_end" }],
        [{ text: "⬅️ " + t("nav_back"), callback_data: "/settings" }]
    ];
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_test_rule(token, chat_id, msg_id, target) {
    if (!target) {
        set_tg_state(chat_id, { action: "test_rule" });
        return send_message(token, chat_id, "🔍 Введите домен или IP для проверки:\n\n<i>Отправьте /cancel для отмены</i>", "HTML");
    }

    let text = "🔍 <b>" + t("test_rule_header") + "</b> <code>" + escape_html(target) + "</code>\n\n";
    let sections = api.get_sections();
    let matched = false;

    // api.get_sections() returns an ARRAY of section objects. In ucode, iterating
    // an array with for..in yields the elements themselves, not indices.
    for (let sec in sections) {
        if (!sec) continue;
        if (sec[".type"] == "settings" || sec[".type"] == "telegram") continue;
        if (sec.enabled == "0") continue;

        let domain_suffix = common.list_option(sec, "domain_suffix");
        let domain = common.list_option(sec, "domain");
        let ip_cidr = common.list_option(sec, "ip_cidr");

        for (let d in domain_suffix) {
            if (target == d || (length(target) > length(d) + 1 && substr(target, length(target) - length(d) - 1) == "." + d)) {
                text += "✅ " + t("test_match") + " <code>" + escape_html(sec[".name"]) + "</code> (domain_suffix)\n";
                text += "   " + t("test_action") + " <code>" + as_string(sec.action || "proxy") + "</code>\n\n";
                matched = true;
            }
        }
        for (let d in domain) {
            if (target == d || target == "full:" + d) {
                text += "✅ " + t("test_match") + " <code>" + escape_html(sec[".name"]) + "</code> (domain)\n";
                text += "   " + t("test_action") + " <code>" + as_string(sec.action || "proxy") + "</code>\n\n";
                matched = true;
            }
        }
        for (let ip in ip_cidr) {
            if (match(target, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) && cidr_match_v4(target, ip)) {
                text += "✅ " + t("test_match") + " <code>" + escape_html(sec[".name"]) + "</code> (ip_cidr)\n";
                text += "   " + t("test_action") + " <code>" + as_string(sec.action || "proxy") + "</code>\n\n";
                matched = true;
            }
        }
    }

    if (!matched) text += "❌ " + t("test_no_match");

    let keyboard = [
        [{ text: "🔄 Ещё раз", callback_data: "/test_rule" }],
        [{ text: "⬅️ " + t("nav_back"), callback_data: "/menu" }]
    ];
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function exec_export_config(token, chat_id, msg_id) {
    let wait_text = "📤 <b>" + t("export_title") + "</b>\n";
    if (msg_id) edit_message(token, chat_id, msg_id, wait_text, "HTML");
    else send_message(token, chat_id, wait_text, "HTML");

    let export_path = "/tmp/tachyon_export_" + time() + ".json";
    let res = command_capture(command_from_args([BIN_PATH, "show_config"]));
    if (res && res.status == 0 && res.output) {
        fs.writefile(export_path, res.output);
        send_document(token, chat_id, export_path);
        // Absent file already satisfies the caller; fs.unlink throws on ENOENT.
        try { fs.unlink(export_path); } catch(e) {}
        send_message(token, chat_id, "✅ " + t("export_done"), "HTML", [[{ text: "⬅️ " + t("nav_menu"), callback_data: "/menu" }]]);
    } else {
        send_message(token, chat_id, "❌ " + t("export_failed"), "HTML", [[{ text: "⬅️ " + t("nav_menu"), callback_data: "/menu" }]]);
    }
}

function view_devices(token, chat_id, msg_id) {
    let lease_file = "/tmp/dhcp.leases";
    let data = fs.readfile(lease_file);
    
    let firewall_c = uci_core.cursor();
    if (firewall_c) firewall_c.load("firewall");
    let blocked_macs = {};
    if (firewall_c) {
        firewall_c.foreach("firewall", "rule", function(r) {
            if (r.target == "REJECT" && r.src_mac) blocked_macs[uc(as_string(r.src_mac))] = true;
        });
    }
    
    let text = "💻 <b>" + t("devices_title") + "</b>\n\n";
    let keyboard = [];
    let count = 0;
    
    if (data) {
        for (let line in split(data, "\n")) {
            line = trim(line);
            if (line == "") continue;
            let fields = split(line, / /);
            if (length(fields) < 4) continue;
            
            let mac = uc(as_string(fields[1]));
            let ip = fields[2];
            let hostname = fields[3] == "*" ? t("device_hostname_unknown") : fields[3];
            
            let is_blocked = blocked_macs[mac];
            let status_icon = is_blocked ? "🚫" : "🟢";
            
            text += status_icon + " <b>" + escape_html(hostname) + "</b>\n";
            text += "└ IP: <code>" + ip + "</code> | MAC: <code>" + mac + "</code>\n\n";
            
            push(keyboard, [{ text: (is_blocked ? "🔓 Разблокировать " : "🚫 Заблокировать ") + hostname, callback_data: "/toggle_mac " + mac }]);
            count++;
        }
    }
    
    if (count == 0) text += "<i>" + t("devices_not_found") + "</i>\n";
    
    push(keyboard, [{ text: "🔄 " + t("btn_refresh"), callback_data: "/devices" }]);
    push(keyboard, [{ text: "⬅️ " + t("nav_back"), callback_data: "/menu" }]);
    
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_watchdog(token, chat_id, msg_id) {
    let running = api.process_running_by_pidfile("/var/run/tachyon_watchdog.pid");
    let text = "🐕 <b>Watchdog Tachyon</b>\n\n" +
               t("status") + ": <code>" + (running ? t("status_running") : t("status_stopped")) + "</code>";
               
    let keyboard = [];
    if (running) {
        push(keyboard, [{ text: "⏹️ Остановить Watchdog", callback_data: "/wd_stop" }]);
        push(keyboard, [{ text: "📊 Полный статус AI", callback_data: "/ai_status_full" }]);
    } else {
        push(keyboard, [{ text: "▶️ Запустить Watchdog", callback_data: "/wd_start" }]);
    }
    push(keyboard, [{ text: "⬅️ " + t("nav_back"), callback_data: "/menu" }]);
    
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function exec_ai_heal(token, chat_id, msg_id) {
    send_message(token, chat_id, "🤖 <b>" + t("heal_running") + "</b>", "HTML");

    command_status(command_from_args(["/usr/bin/tachyon", "ai_heal"]));

    let status_data = fs.readfile("/tmp/tachyon_ai_status.json");
    let text = "🤖 <b>[" + t("ai_doctor_title") + "]</b>\n\n";
    if (status_data) {
        try {
            let st = json(status_data);
            if (st.last_incident) {
                text += "⚠️ <b>" + t("ai_incident") + "</b> " + escape_html(st.last_incident.description || "") + "\n";
                text += "🔧 <b>" + t("ai_resolution") + "</b> " + escape_html(st.last_incident.resolution || "") + "\n\n";
                text += t("status_normal");
            } else {
                text += "🟢 " + t("ai_all_ok");
            }
        } catch(e) {
            text += "🟢 " + t("ai_diag_ok");
        }
    } else {
        text += "🟢 " + t("ai_diag_done");
    }

    let keyboard = [[{ text: "⬅️ В меню", callback_data: "/menu" }]];
    send_message(token, chat_id, text, "HTML", keyboard);
}

function exec_ai_status_full(token, chat_id, msg_id) {
    send_message(token, chat_id, "🔍 <b>" + t("ai_status_collecting") + "</b>", "HTML");
    let res = command_capture(command_from_args([ "/usr/bin/tachyon", "ai_status_full" ]));
    let data = res ? (res.output || t("err_no_data")) : t("ai_status_error");
    if (length(data) > 3500) data = substr(data, 0, 3500) + "\n... (" + t("ai_data_truncated") + ")";
    let text = "🤖 <b>" + t("ai_full_status_header") + "</b>\n\n<pre>" + escape_html(data) + "</pre>";
    let keyboard = [[{ text: "⬅️ " + t("nav_back"), callback_data: "/watchdog" }]];
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_qos(token, chat_id, msg_id) {
    let c = uci_core.cursor(); c.load(CONFIG_NAME);
    let cfg = c.get_all(CONFIG_NAME, "settings") || {};
    let enabled = cfg.qos_priority_engine != "0";
    
    let text = "🎮 <b>" + t("qos_title") + "</b>\n\n" +
               t("quiet_status") + ": <code>" + (enabled ? "🟢 " + t("qos_enabled_detail") : "⚪ " + t("qos_disabled_detail")) + "</code>\n\n" +
               "<b>" + t("qos_priority_rules") + "</b>\n" +
               "├ 🎙️ <b>Golos/Discord/RTC:</b> UDP 5000-5020, 3478, 19302 ➔ <code>DSCP EF (0x2e)</code>\n" +
               "├ 🎮 <b>Games (Steam/CS/Dota/Apex/PUBG/Roblox):</b> UDP 27000-27050, 3074 ➔ <code>DSCP AF41 (0x22)</code>\n" +
               "└ ⚡ <b>TCP ACK Acceleration:</b> малые ACK пакеты ➔ <code>High Priority</code>";

    let keyboard = [
        [{ text: (enabled ? "⏹️ Отключить QoS" : "⚡ Включить QoS"), callback_data: "/qos_toggle" }],
        [{ text: "⬅️ " + t("nav_back"), callback_data: "/menu" }]
    ];
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

return {
    view_settings_menu,
    view_set_list,
    view_set_cat,
    view_set_arr,
    view_menu,
    view_status,
    view_runtime,
    view_outbounds,
    save_persistent_selector_choice,
    view_sections,
    view_section_editor,
    view_sec_list,
    exec_doctor,
    exec_restart,
    restore_config_from_backup,
    exec_backup,
    exec_support_bundle,
    exec_close_connections,
    exec_check_updates,
    view_instances,
    exec_speedtest,
    view_ping,
    view_quick_test,
    view_logs,
    view_system_info,
    view_connections,
    view_sec_subs,
    view_help,
    view_language,
    view_guest_mode,
    view_quiet_hours,
    view_test_rule,
    exec_export_config,
    view_devices,
    view_watchdog,
    exec_ai_heal,
    exec_ai_status_full,
    view_qos
};
