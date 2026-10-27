#!/usr/bin/env ucode
//
// Telegram bot command views and diagnostic executors.
// Extracted from service/telegram.uc (Branch 7 god-module refactor).
//

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
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
let setting_schema = rendering.setting_schema;
let get_schema_label = rendering.get_schema_label;
let is_boolean_key = rendering.is_boolean_key;
let is_list_key = rendering.is_list_key;
let cidr_match_v4 = rendering.cidr_match_v4;
let build_label = rendering.build_label;
let build_transition = rendering.build_transition;
let build_identity_key = rendering.build_identity_key;
let extract_clean_fptn_token = rendering.extract_clean_fptn_token;
let mask_fptn_token = rendering.mask_fptn_token;
let section_condition_sections = rendering.section_condition_sections;
let section_own_and_conditions = rendering.section_own_and_conditions;
let section_primary_atomic_condition = rendering.section_primary_atomic_condition;
let section_match_all_enabled = rendering.section_match_all_enabled;
let section_condition_values = rendering.section_condition_values;
let section_outbound_sources = rendering.section_outbound_sources;
let section_has_fptn = rendering.section_has_fptn;
let section_fptn_token = rendering.section_fptn_token;
let section_balancers = rendering.section_balancers;
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
        [{ text: t("menu_router_name"), callback_data: "/name" }],
        [
            { text: t("menu_sections"), callback_data: "/set_list section" },
            { text: t("cat_conditions"), callback_data: "/set_list condition" }
        ],
        [
            { text: t("cat_outbound_sources"), callback_data: "/set_list outbound_source" },
            { text: t("cat_balancers"), callback_data: "/set_list balancer" }
        ],
        [
            { text: t("cat_outbound_groups"), callback_data: "/set_list outbound_group" },
            { text: t("menu_servers_short"), callback_data: "/set_list server" }
        ],
        [{ text: t("menu_subscriptions"), callback_data: "/set_list subscription_url" }],
        [{ text: t("menu_dns_presets"), callback_data: "/dns_presets" }],
        [{ text: t("menu_quiet_hours"), callback_data: "/qh" }],
        [{ text: t("menu_guest"), callback_data: "/guest" }],
        [{ text: t("menu_language"), callback_data: "/lang" }],
        [{ text: t("menu_test_rule"), callback_data: "/test_rule" }],
        [{ text: t("menu_export_config"), callback_data: "/export_config" }],
        [{ text: t("menu_restart"), callback_data: "/reload_tachyon" }],
        [{ text: t("menu_restore_internet"), callback_data: "/restore_internet" }],
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
            let label = s.label || s.name || s.url || sname;
            let suffix = "";
            if (stype == "outbound_source" && s.source_type)
                suffix = " [" + s.source_type + "]";
            else if (stype == "balancer" && s.mode)
                suffix = " [" + s.mode + "]";
            else if (stype == "section" && s.action)
                suffix = " [" + s.action + "]";
            else if (stype == "condition")
                suffix = s.condition_expression ? " [formula]" : "";
            if (length(label) > 26) label = substr(label, 0, 26) + "...";
            let status_prefix = (stype == "condition") ? "🧩 " : (s.enabled == "0" ? "❌ " : "✅ ");
            push(keyboard, [{ text: status_prefix + label + suffix, callback_data: "/set_cat " + stype + " " + sname }]);
        }
    }
    push(keyboard, [{ text: t("menu_categories"), callback_data: "/settings" }]);
    let text = "⚙️ <b>" + escape_html(stype) + "</b>\n" + t("choose_section");
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
    
    if (stype == "server" || stype == "section" || stype == "subscription_url" || stype == "condition" || stype == "outbound_source" || stype == "outbound_group" || stype == "balancer") {
        push(keyboard, [{ text: t("btn_delete") + " " + sname, callback_data: "/set_del " + stype + " " + sname }]);
    }
    
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
        if (section_has_fptn(sections[i])) {
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
    let engine_label = (sys && sys.engine_name) ? sys.engine_name : "tachyon-core";
    let text = "📊 <b>" + t("menu_status") + "</b>\n\n" +
               t("status_version") + ": <code>" + (sys.tachyon_version || "?") + "</code>\n" +
               t("status_uptime") + ": <code>" + sys.uptime + "</code>\n" +
               t("status_cpu") + ": <code>" + sys.cpu + "</code>\n" +
               "RAM: <code>" + sys.ram_avail + "MB / " + sys.ram_total + "MB</code>\n\n" +
               escape_html(engine_label) + ": <code>" + sys.singbox + (sys.singbox_variant && sys.singbox_variant != engine_label ? " [" + sys.singbox_variant + "]" : "") + "</code>\n" +
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

function view_outbounds(token, chat_id, msg_id, group_name, page) {
    page = int(page || 0);
    if (page < 0) page = 0;
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
        let servers = group_data.all || [];
        // A group can hold hundreds of nodes, and Telegram truncates a message
        // well before the list ends. Paginate instead: the text and the keyboard
        // must show the same window, or the tail is unreachable.
        let total = length(servers);
        let per_page = 16;
        let total_pages = int((total + per_page - 1) / per_page);
        if (total_pages < 1) total_pages = 1;
        if (page > total_pages - 1) page = total_pages - 1;
        let start = page * per_page;
        let end = start + per_page;
        if (end > total) end = total;

        for (let i = start; i < end; i++) {
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

            push(row, { text: (name == active_server ? "🔵 " : "") + name, callback_data: cb_data([ "/sw", group_name, name ]) });
            if (length(row) == 2) {
                push(keyboard, row);
                row = [];
            }
        }
        if (length(row) > 0) push(keyboard, row);

        if (total == 0) text += "<i>" + t("servers_not_found") + "</i>\n";
        else text += "\nℹ️ " + t("outbounds_hint");

        if (total_pages > 1) {
            let nav = [];
            if (page > 0) push(nav, { text: t("nav_prev"), callback_data: "/outbounds " + as_string(page - 1) + " " + group_name });
            push(nav, { text: as_string(page + 1) + "/" + as_string(total_pages), callback_data: "/noop" });
            if (end < total) push(nav, { text: t("nav_next"), callback_data: "/outbounds " + as_string(page + 1) + " " + group_name });
            push(keyboard, nav);
        }

        push(keyboard, [{ text: t("btn_refresh"), callback_data: "/outbounds " + as_string(page) + " " + group_name }]);
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
        let act = s.action || "connection";
        let sources = section_outbound_sources(s);
        let conds = section_condition_sections(s);
        let badge = act;
        if (act == "connection" && length(sources) > 0) {
            let stypes = [];
            for (let src in sources) {
                let st = src.source_type || "subscription";
                let found = false;
                for (let x in stypes) if (x == st) { found = true; break; }
                if (!found) push(stypes, st);
            }
            badge = join("+", stypes);
        } else if (act == "dns" && s.dns_server) {
            badge = "dns:" + (s.dns_type || "doh");
        } else if (act == "group") {
            badge = "group:" + length(common.list_option(s, "group_members"));
        }
        text += status + " <b>" + escape_html(label) + "</b> <code>[" + escape_html(badge) + "]</code>";
        if (length(conds) > 0)
            text += " • 🧩" + length(conds);
        text += "\n";
        push(keyboard, [{ text: status + " " + label + " [" + badge + "]", callback_data: "/sec_view " + s[".name"] }]);
    }
    
    push(keyboard, [{ text: t("section_create"), callback_data: "/sec_create" }]);
    push(keyboard, [
        { text: t("cat_conditions"), callback_data: "/set_list condition" },
        { text: t("cat_outbound_sources"), callback_data: "/set_list outbound_source" }
    ]);
    push(keyboard, [
        { text: t("cat_balancers"), callback_data: "/set_list balancer" },
        { text: t("menu_test_rule"), callback_data: "/test_rule" }
    ]);
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
    let act = s.action || "connection";
    let text = "⚙️ <b>" + t("section_section") + ":</b> " + escape_html(s.label || s.name || sec_name) + " (<code>" + escape_html(sec_name) + "</code>)\n" +
               t("section_type") + ": <code>" + escape_html(act) + "</code>\n" +
               t("section_status") + ": <b>" + status + "</b>\n\n";
               
    if (act == "proxy" || act == "route" || (act == "connection" && s.target)) {
        text += t("status_target") + ": <code>" + escape_html(s.target || "main-out") + "</code>\n";
    }
    if (act == "dns") {
        let dtype = s.dns_type || "doh";
        let dsrv = s.dns_server || "(не задан)";
        text += "🌐 <b>" + t("section_dns_target") + ":</b> <code>" + escape_html(dtype + "://" + dsrv) + "</code>\n";
    }
    let grp_members = common.list_option(s, "group_members");
    if (act == "group") {
        text += "🗂 <b>" + t("section_group_members") + ":</b> " + (length(grp_members) > 0 ? "<code>" + escape_html(join(" → ", grp_members)) + "</code>" : "<i>(пусто)</i>") + "\n";
    }
    let has_fptn = section_has_fptn(s);
    if (has_fptn) {
        let tok = section_fptn_token(s);
        text += "🔑 Token: <code>" + escape_html(mask_fptn_token(tok)) + "</code>\n";
    }
    
    let d_count = length(section_condition_values(s, "domain_suffix")) +
                  length(section_condition_values(s, "domain")) +
                  length(section_condition_values(s, "domain_keyword")) +
                  length(section_condition_values(s, "domain_regex"));
    let ip_count = length(section_condition_values(s, "ip_cidr")) +
                   length(section_condition_values(s, "ip")) +
                   length(section_condition_values(s, "subnets"));
    let src_count = length(section_condition_values(s, "source_ip_cidr")) +
                    length(section_condition_values(s, "source_macs")) +
                    length(section_condition_values(s, "devices"));
    let rs_count = length(section_condition_values(s, "community_lists")) +
                   length(section_condition_values(s, "rule_set")) +
                   length(section_condition_values(s, "rule_set_with_subnets")) +
                   length(section_condition_values(s, "domain_ip_lists"));
    let port_vals = section_condition_values(s, "ports");
    let geoip_vals = section_condition_values(s, "geoip_country");
    let is_match_all = section_match_all_enabled(s);

    // The conditions a section is built from are reusable entities now, so
    // the section has to name them - otherwise the user has no idea which
    // condition a section really uses.
    let cond_list = section_condition_sections(s);
    let cond_names = [];
    for (let cond in cond_list) {
        let cname = cond.label || cond.name || cond[".name"];
        let ctype = cond.condition_expression ? "formula" : (cond.condition_type || "atomic");
        push(cond_names, escape_html(cname) + " <i>(" + escape_html(ctype) + ")</i>");
    }

    let sources = section_outbound_sources(s);
    let src_names = [];
    for (let src in sources) {
        let sname = src.label || src.name || src[".name"];
        let stype = src.source_type || "subscription";
        let detail = stype;
        if (stype == "zapret2" && src.zapret2_strategy)
            detail = stype + ":" + src.zapret2_strategy;
        else if (stype == "desync" && src.desync_mode)
            detail = stype + ":" + src.desync_mode;
        else if (stype == "interface" && src.interface)
            detail = stype + ":" + src.interface;
        push(src_names, escape_html(sname) + " <i>(" + escape_html(detail) + ")</i>");
    }

    let balancers = section_balancers(s);
    let bal_names = [];
    for (let bal in balancers) {
        let bname = bal.label || bal.name || bal[".name"];
        let btype = bal.mode || bal.balancer_type || bal[".type"] || "urltest";
        push(bal_names, escape_html(bname) + " <i>(" + escape_html(btype) + ")</i>");
    }

    if (length(cond_names) > 0) {
        text += "🧩 <b>" + t("section_conditions") + ":</b> " + join(", ", cond_names) + "\n";
    }
    if (s.condition_expression) {
        text += "📐 <b>" + t("condition_expression") + ":</b> <code>" + escape_html(s.condition_expression) + "</code>\n";
    }
    if (is_match_all) {
        text += "🌍 <b>" + t("section_match_all_on") + "</b>\n";
    }
    if (length(geoip_vals) > 0) {
        text += "🗺 <b>" + t("section_geoip") + ":</b> <code>" + escape_html(join(", ", geoip_vals)) + "</code>\n";
    }
    if (length(port_vals) > 0) {
        text += "🔌 <b>" + t("section_ports") + ":</b> <code>" + escape_html(join(", ", port_vals)) + "</code>\n";
    }
    if (length(src_names) > 0) {
        text += "📡 <b>" + t("cat_outbound_sources") + ":</b> " + join(", ", src_names) + "\n";
    }
    if (length(bal_names) > 0) {
        text += "⚡ <b>" + t("section_balancers") + ":</b> " + join(", ", bal_names) + "\n";
    }
    text += "\n";

    let keyboard = [];
    push(keyboard, [
        { text: (s.enabled == "1" ? "🔴 " + t("status_disabled") : "🟢 " + t("status_enabled")), callback_data: "/sec_toggle " + sec_name },
        { text: t("btn_rename"), callback_data: "/sec_rename " + sec_name }
    ]);

    push(keyboard, [{ text: t("section_action") + ": " + act, callback_data: "/sec_action " + sec_name }]);
    if (act == "proxy" || act == "route") {
        push(keyboard, [{ text: t("status_target") + ": " + (s.target || "main-out"), callback_data: "/sec_target " + sec_name }]);
    }
    if (act == "dns") {
        push(keyboard, [{ text: t("btn_sec_dns_edit"), callback_data: "/sec_dns_edit " + sec_name }]);
    }
    if (act == "group") {
        push(keyboard, [{ text: t("btn_sec_group_members", length(grp_members)), callback_data: "/sec_grp " + sec_name }]);
    }
    if (has_fptn) {
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
    push(keyboard, [
        { text: t("btn_sec_ports", length(port_vals)), callback_data: "/sec_list " + sec_name + " ports" },
        { text: t("btn_sec_geoip", length(geoip_vals)), callback_data: "/sec_list " + sec_name + " geoip" }
    ]);

    push(keyboard, [
        { text: t("btn_sec_conditions", length(cond_list)), callback_data: "/sec_conds " + sec_name },
        { text: t("btn_sec_balancers", length(balancers)), callback_data: "/sec_bals " + sec_name }
    ]);

    push(keyboard, [{ text: t("menu_subscriptions") + " (" + length(sources) + ")", callback_data: "/sec_subs " + sec_name }]);
    
    push(keyboard, [{ text: t("btn_delete_section"), callback_data: "/sec_delete " + sec_name }]);
    push(keyboard, [{ text: t("btn_back_to_sections"), callback_data: "/sections" }]);
    
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_sec_conds(token, chat_id, msg_id, sec_name) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let s = c.get_all(CONFIG_NAME, sec_name);
    if (!s) return view_sections(token, chat_id, msg_id);

    let all = c.get_all(CONFIG_NAME);
    let linked_refs = common.list_option(s, "condition_refs");
    let linked_map = {};
    for (let r in linked_refs) linked_map[r] = true;

    let eff_conds = section_condition_sections(s);
    let eff_map = {};
    for (let ec in eff_conds) eff_map[ec[".name"]] = true;

    let text = t("sec_conds_header") + " <code>" + escape_html(s.label || sec_name) + "</code>\n\n";
    if (s.condition_expression) {
        text += "📐 <b>" + t("condition_expression") + ":</b> <code>" + escape_html(s.condition_expression) + "</code>\n\n";
    }

    let keyboard = [];
    let has_linked = false;
    text += "<b>" + t("sec_conds_linked") + "</b>\n";
    for (let ec in eff_conds) {
        has_linked = true;
        let cname = ec[".name"];
        let clabel = ec.label || ec.name || cname;
        let cdesc = ec.condition_expression ? ("formula: " + ec.condition_expression) : "atomic";
        text += "• <b>" + escape_html(clabel) + "</b> (<code>" + escape_html(cname) + "</code> — " + escape_html(cdesc) + ")\n";
        let row = [{ text: "✏️ " + clabel, callback_data: "/set_cat condition " + cname }];
        if (linked_map[cname])
            push(row, { text: t("btn_unlink"), callback_data: "/sec_cond_tog " + sec_name + " " + cname });
        push(keyboard, row);
    }
    if (!has_linked) {
        text += "<i>(нет привязанных условий)</i>\n";
    }

    let avail_rows = [];
    for (let sname in all) {
        let item = all[sname];
        if (item[".type"] != "condition" || linked_map[sname])
            continue;
        let clabel = item.label || item.name || sname;
        if (length(clabel) > 22) clabel = substr(clabel, 0, 22) + "...";
        push(avail_rows, [
            { text: t("btn_link") + ": " + clabel, callback_data: "/sec_cond_tog " + sec_name + " " + sname },
            { text: "✏️", callback_data: "/set_cat condition " + sname }
        ]);
    }
    if (length(avail_rows) > 0) {
        text += "\n<b>" + t("sec_conds_available") + "</b> " + length(avail_rows) + "\n";
        for (let i = 0; i < length(avail_rows) && i < 12; i++)
            push(keyboard, avail_rows[i]);
    }

    let is_match_all = section_match_all_enabled(s);
    push(keyboard, [
        { text: (is_match_all ? t("btn_sec_match_all_on") : t("btn_sec_match_all_off")), callback_data: "/sec_match_all " + sec_name },
        { text: t("btn_create_condition"), callback_data: "/sec_cond_new " + sec_name }
    ]);
    push(keyboard, [{ text: "🔙 " + t("btn_back_to_section"), callback_data: "/sec_view " + sec_name }]);

    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_sec_bals(token, chat_id, msg_id, sec_name) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let s = c.get_all(CONFIG_NAME, sec_name);
    if (!s) return view_sections(token, chat_id, msg_id);

    let all = c.get_all(CONFIG_NAME);
    let linked_refs = common.list_option(s, "balancer_refs");
    let linked_map = {};
    for (let r in linked_refs) linked_map[r] = true;

    let text = t("sec_bals_header") + " <code>" + escape_html(s.label || sec_name) + "</code>\n\n";
    let keyboard = [];
    let bals = section_balancers(s);
    if (length(bals) == 0) {
        text += "<i>(нет привязанных балансировщиков)</i>\n";
    } else {
        text += "<b>" + t("sec_bals_linked") + "</b>\n";
        for (let b in bals) {
            let bname = b[".name"];
            let blabel = b.label || b.name || bname;
            let bmode = b.mode || b.balancer_type || b[".type"] || "urltest";
            text += "• <b>" + escape_html(blabel) + "</b> (<code>" + escape_html(bmode) + "</code>)\n";
            let row = [{ text: "✏️ " + blabel + " [" + bmode + "]", callback_data: "/set_cat balancer " + bname }];
            if (linked_map[bname])
                push(row, { text: t("btn_unlink"), callback_data: "/sec_bal_tog " + sec_name + " " + bname });
            push(keyboard, row);
        }
    }

    for (let sname in all) {
        let item = all[sname];
        if (item[".type"] != "balancer" || linked_map[sname])
            continue;
        let blabel = item.label || item.name || sname;
        let bmode = item.mode || "urltest";
        push(keyboard, [
            { text: t("btn_link") + ": " + blabel + " [" + bmode + "]", callback_data: "/sec_bal_tog " + sec_name + " " + sname },
            { text: "✏️", callback_data: "/set_cat balancer " + sname }
        ]);
    }

    push(keyboard, [{ text: "🔙 " + t("btn_back_to_section"), callback_data: "/sec_view " + sec_name }]);
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_sec_grp(token, chat_id, msg_id, sec_name) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let s = c.get_all(CONFIG_NAME, sec_name);
    if (!s) return view_sections(token, chat_id, msg_id);

    let all = c.get_all(CONFIG_NAME);
    let members = common.list_option(s, "group_members");
    let mem_map = {};
    for (let m in members) mem_map[m] = true;

    let text = t("sec_grp_header") + " <code>" + escape_html(s.label || sec_name) + "</code>\n\n";
    let keyboard = [];
    if (length(members) == 0) {
        text += "<i>(нет участников в группе)</i>\n";
    } else {
        text += "<b>" + t("sec_grp_linked") + "</b>\n";
        for (let i = 0; i < length(members); i++) {
            let mname = members[i];
            let ms = all[mname] || {};
            let mlabel = ms.label || ms.name || mname;
            text += as_string(i + 1) + ". <b>" + escape_html(mlabel) + "</b> (<code>" + escape_html(mname) + "</code>)\n";
            push(keyboard, [
                { text: "⬆️ #" + as_string(i + 1) + " " + mlabel, callback_data: "/sec_view " + mname },
                { text: t("btn_unlink"), callback_data: "/sec_grp_tog " + sec_name + " " + mname }
            ]);
        }
    }

    for (let sname in all) {
        let item = all[sname];
        if (item[".type"] != "section" || sname == sec_name || mem_map[sname])
            continue;
        let mlabel = item.label || item.name || sname;
        push(keyboard, [{ text: t("btn_link") + ": " + mlabel + " [" + (item.action || "connection") + "]", callback_data: "/sec_grp_tog " + sec_name + " " + sname }]);
    }

    push(keyboard, [{ text: "🔙 " + t("btn_back_to_section"), callback_data: "/sec_view " + sec_name }]);
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
    // The values live in the section's own fields and in the conditions it
    // is built from - a modular section carries them in the condition.
    if (list_type == "domain") {
        title = t("section_domains");
        for (let x in section_condition_values(s, "domain_suffix")) push(items, {type: "domain_suffix", val: x});
        for (let x in section_condition_values(s, "domain")) push(items, {type: "domain", val: x});
        for (let x in section_condition_values(s, "domain_keyword")) push(items, {type: "domain_keyword", val: x});
        for (let x in section_condition_values(s, "domain_regex")) push(items, {type: "domain_regex", val: x});
    } else if (list_type == "ip") {
        title = t("section_ips");
        for (let x in section_condition_values(s, "ip_cidr")) push(items, {type: "ip_cidr", val: x});
        for (let x in section_condition_values(s, "ip")) push(items, {type: "ip", val: x});
        for (let x in section_condition_values(s, "subnets")) push(items, {type: "subnets", val: x});
    } else if (list_type == "src") {
        title = t("section_sources");
        for (let x in section_condition_values(s, "source_ip_cidr")) push(items, {type: "source_ip_cidr", val: x});
        for (let x in section_condition_values(s, "source_macs")) push(items, {type: "source_macs", val: x});
        for (let x in section_condition_values(s, "devices")) push(items, {type: "devices", val: x});
    } else if (list_type == "ruleset") {
        title = "Rulesets / Community";
        for (let x in section_condition_values(s, "community_lists")) push(items, {type: "community_lists", val: x});
        for (let x in section_condition_values(s, "rule_set")) push(items, {type: "rule_set", val: x});
        for (let x in section_condition_values(s, "rule_set_with_subnets")) push(items, {type: "rule_set_with_subnets", val: x});
        for (let x in section_condition_values(s, "domain_ip_lists")) push(items, {type: "domain_ip_lists", val: x});
    } else if (list_type == "ports") {
        title = t("section_ports");
        for (let x in section_condition_values(s, "ports")) push(items, {type: "ports", val: x});
    } else if (list_type == "geoip") {
        title = t("section_geoip");
        for (let x in section_condition_values(s, "geoip_country")) push(items, {type: "geoip_country", val: x});
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
    let sb_mod = require("service.support_bundle");
    let res = sb_mod ? sb_mod.create_bundle() : { ok: false, error: "Module unavailable" };
    
    if (res.ok && res.bundle_path && fs.stat(res.bundle_path)) {
        send_document(token, chat_id, res.bundle_path);
        try { fs.unlink(res.bundle_path); } catch(e) {}
    } else {
        let err_msg = res.error ? (": " + escape_html(res.error)) : "";
        send_message(token, chat_id, "❌ <b>" + t("support_bundle_error") + err_msg + "</b>", "HTML");
    }
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
                    let title = rendering.component_display_title(comp);
                    let cur = comp.current_version || "?";
                    let lat = comp.latest_version || "?";
                    if (!comp.success) {
                        text += "• <b>" + title + "</b>: ❌ Ошибка проверки\n";
                    } else if (comp.status == "outdated_same_release") {
                        let transition = build_transition(comp);
                        text += "• <b>" + title + "</b>: <code>" + cur + "</code> — " + t("update_new_release_build") +
                            (transition != "" ? " " + transition : "") + " ⚠️\n";
                        let notes = rendering.clean_release_notes(comp.release_notes);
                        if (notes != "") {
                            if (length(notes) > 400)
                                notes = substr(notes, 0, 400) + "...";
                            text += "  📋 <b>" + t("update_whats_new") + ":</b>\n<pre>" + escape_html(notes) + "</pre>\n";
                        }
                        push(keyboard, [{text: t("btn_update_component") + " " + title, callback_data: "/update_component " + name}]);
                        has_updates = true;
                    } else if (comp.status == "outdated") {
                        text += "• <b>" + title + "</b>: <code>" + cur + "</code> ➡️ <code>" + lat + "</code> ⚠️\n";
                        let notes = rendering.clean_release_notes(comp.release_notes);
                        if (notes != "") {
                            if (length(notes) > 400)
                                notes = substr(notes, 0, 400) + "...";
                            text += "  📋 <b>" + t("update_whats_new") + ":</b>\n<pre>" + escape_html(notes) + "</pre>\n";
                        }
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
    let engine_label = (sys && sys.engine_name) ? sys.engine_name : "tachyon-core";

    text += (conn && conn.direct ? "✅" : "❌") + " " + t("test_direct") + "\n";
    text += (conn && conn.proxy ? "✅" : "❌") + " " + t("test_proxy") + "\n";
    text += (sys && sys.singbox_running ? "✅" : "❌") + " " + escape_html(engine_label) + "\n";
    text += (sys && sys.tachyon_running ? "✅" : "❌") + " " + t("test_service") + "\n";
    text += (sys && sys.watchdog_running ? "✅" : "❌") + " Watchdog\n";

    let nft = command_capture(command_from_args(["/usr/sbin/nft", "list", "tables"]));
    text += (nft && nft.status == 0 && match(nft.output || "", /TachyonTable|\bsteer\b/)) ? "✅" : "❌";
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
                    push(filtered, "UDP traffic through HTTP outbounds is not supported; repeated UDP warnings for HTTP outbounds are hidden by Tachyon.");
                    udp_http_notice_emitted = true;
                }
                continue;
            }
            if (level == "error" && !match(line, /\[err\]|\[error\]/i)) continue;
            if (level == "warn" && !match(line, /\[warn\]/i)) continue;
            if (level == "info" && !match(line, /\[info\]/i)) continue;
            if (match(line, /tachyon|tachyon-core|sing-box|steer|watchdog/i)) push(filtered, line);
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
            let active_engine = "tachyon-core";
            try { active_engine = require("core.engine").get_active(); } catch (e) {}
            if (active_engine == "steer" || active_engine == "steer-extended") {
                text += "📦 steer: <code>" + as_string(info.steer_version || "N/A") + "</code>\n";
                if (info.steer_extended == "1" || active_engine == "steer-extended")
                    text += "   Variant: Extended 🔵\n";
            } else if (info.sing_box_tachyon_core == 1 || active_engine == "tachyon-core") {
                text += "📦 tachyon-core: <code>" + as_string(info.tachyon_core_version || info.sing_box_version || "N/A") + "</code>\n";
            } else {
                text += "📦 sing-box: <code>" + as_string(info.sing_box_version || "N/A") + "</code>\n";
                if (info.sing_box_lx == 1) text += "   Fork: Leadaxe (lx) 🟢\n";
                else if (info.sing_box_compressed == 1) text += "   Fork: Extended (compressed) 🔵\n";
                else if (info.sing_box_extended == 1) text += "   Fork: Extended (shtorm-7) 🔵\n";
                else if (info.sing_box_tiny == 1) text += "   Variant: Tiny 🟡\n";
                else text += "   Variant: Official / Stock ⚪\n";
            }
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
    let s = c.get_all(CONFIG_NAME, sec_name);
    if (!s) return;
    let all = c.get_all(CONFIG_NAME);
    let direct_refs = common.list_option(s, "outbound_source_refs");
    let direct_map = {};
    for (let r in direct_refs) direct_map[r] = true;

    let eff_sources = section_outbound_sources(s);
    let eff_map = {};
    let keyboard = [];
    let count = 0;
    let text = "🔗 <b>" + t("sub_section_subs") + " " + escape_html(s.label || sec_name) + "</b>\n\n";

    // The sources are reusable entities now, so a section points at them
    // instead of carrying its own subscription children.
    for (let src in eff_sources) {
        let sname = src[".name"];
        eff_map[sname] = true;
        let label = src.label || src.name || src.url || sname;
        if (length(label) > 26) label = substr(label, 0, 26) + "...";
        let icon = src.enabled == "0" ? "❌" : "✅";
        let stype = src.source_type || (src[".type"] == "subscription_url" ? "subscription" : "subscription");
        let cat_type = src[".type"] || "outbound_source";
        text += icon + " <b>" + escape_html(src.label || src.name || sname) + "</b> <code>[" + escape_html(stype) + "]</code>";
        if (src.url) text += "\n   └ <code>" + escape_html(length(src.url) > 45 ? substr(src.url, 0, 45) + "..." : src.url) + "</code>";
        else if (src.zapret2_strategy) text += " (<code>" + escape_html(src.zapret2_strategy) + "</code>)";
        else if (src.desync_mode) text += " (<code>" + escape_html(src.desync_mode) + "</code>)";
        text += "\n";

        push(keyboard, [
            { text: icon + " [" + stype + "] " + label, callback_data: "/set_cat " + cat_type + " " + sname },
            { text: t("btn_sub_delete"), callback_data: "/sec_sub_del " + sec_name + " " + sname }
        ]);
        count++;
    }

    if (count == 0) {
        text += t("sub_none") + "\n";
    } else {
        text += "\n" + t("sub_found_count") + " " + count + "\n";
    }

    // Offer existing outbound_source sections that are not yet linked
    let avail = [];
    for (let sname in all) {
        let item = all[sname];
        if (item[".type"] != "outbound_source" || eff_map[sname])
            continue;
        let slabel = item.label || item.name || sname;
        if (length(slabel) > 22) slabel = substr(slabel, 0, 22) + "...";
        let stype = item.source_type || "subscription";
        push(avail, [
            { text: t("btn_link") + ": " + slabel + " [" + stype + "]", callback_data: "/sec_src_tog " + sec_name + " " + sname },
            { text: "✏️", callback_data: "/set_cat outbound_source " + sname }
        ]);
    }
    if (length(avail) > 0) {
        for (let i = 0; i < length(avail) && i < 10; i++)
            push(keyboard, avail[i]);
    }

    push(keyboard, [{ text: "➕ " + t("btn_add_subscription"), callback_data: "/sec_sub_add " + sec_name }]);
    push(keyboard, [{ text: "🔙 " + t("nav_back"), callback_data: "/sec_view " + sec_name }]);
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
        "/name — " + t("cmd_name") + "\n" +
        "/dns_presets — DNS пресеты\n" +
        "/help — " + t("help_this");

    let keyboard = [[{ text: "⬅️ " + t("nav_menu"), callback_data: "/menu" }]];
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_router_name(token, chat_id, msg_id) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let cur = trim(as_string(option(c.get_all(CONFIG_NAME, "telegram"), "router_name", "")));
    let cur_display = (cur != "") ? ("<code>" + escape_html(cur) + "</code>") : ("<i>" + t("router_name_not_set") + "</i>");
    let text = "🖥 <b>" + t("router_name_title") + "</b>\n\n" +
        t("router_name_current", cur_display) + "\n\n" +
        "<i>" + t("router_name_hint") + "</i>";
    let keyboard = [
        [{ text: t("btn_router_name_change"), callback_data: "/name_prompt" }]
    ];
    if (cur != "") {
        push(keyboard, [{ text: t("btn_router_name_clear"), callback_data: "/name_clear" }]);
    }
    push(keyboard, [{ text: t("nav_back"), callback_data: "/settings" }]);
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

    target = trim(as_string(target));
    target = replace(target, /^https?:\/\//i, "");
    target = split(target, "/")[0];

    let text = "🔍 <b>" + t("test_rule_header") + "</b> <code>" + escape_html(target) + "</code>\n\n";
    let sections = api.get_sections();
    let matched = false;

    // 1. Run full 7-stage route_explain pipeline when available
    try {
        let re_mod = require("diagnostics.route_explain");
        if (re_mod && type(re_mod.explain_route) == "function") {
            let exp = re_mod.explain_route("192.168.1.100", target, 443, "tcp");
            if (type(exp) == "object" && exp.success) {
                let v = exp.verdict || "direct";
                let v_icon = "🟢";
                if (v == "proxied") v_icon = "🚀";
                else if (v == "dns") v_icon = "🌐";
                else if (v == "blocked") v_icon = "🛑";
                else if (v == "hosts") v_icon = "📝";
                else if (v == "zapret" || v == "byedpi") v_icon = "🛡";

                if (exp.matched_section && exp.matched_section != "default") {
                    matched = true;
                    let mrule = exp.matched_rule || {};
                    let st4 = (exp.stages && exp.stages["4_dns_decision"]) || {};
                    let st7 = (exp.stages && exp.stages["7_engine_outbound"]) || {};
                    text += v_icon + " <b>Вердикт:</b> <code>" + escape_html(v) + "</code>\n";
                    text += "✅ " + t("test_match") + " <code>" + escape_html(exp.matched_section) + "</code>";
                    if (mrule.type)
                        text += " (" + escape_html(mrule.type + (mrule.value ? ": " + mrule.value : "")) + ")";
                    text += "\n";
                    text += "   " + t("test_action") + " <code>" + escape_html(mrule.action || v) + "</code>\n";
                    if (st7.selected_node)
                        text += "   📤 Выход: <code>" + escape_html(st7.group_tag + " → " + st7.selected_node) + "</code>\n";
                    if (st4.strategy)
                        text += "   🌐 DNS: <code>" + escape_html(st4.strategy + (st4.server ? " (" + st4.server + ")" : "")) + "</code>\n";
                    if (exp.explanation && exp.explanation.ru)
                        text += "   💬 <i>" + escape_html(exp.explanation.ru) + "</i>\n";
                    text += "\n";
                }
            }
        }
    } catch (e) {}

    // 2. Also inspect section_condition_values across all enabled sections
    // (covers both inline fields and linked condition entities).
    for (let sec in sections) {
        if (!sec) continue;
        if (sec[".type"] == "settings" || sec[".type"] == "telegram") continue;
        if (sec.enabled == "0") continue;

        let domain_suffix = section_condition_values(sec, "domain_suffix");
        let domain = section_condition_values(sec, "domain");
        let domain_keyword = section_condition_values(sec, "domain_keyword");
        let ip_cidr = section_condition_values(sec, "ip_cidr");

        for (let d in domain_suffix) {
            if (target == d || (length(target) > length(d) + 1 && substr(target, length(target) - length(d) - 1) == "." + d)) {
                text += "✅ " + t("test_match") + " <code>" + escape_html(sec[".name"]) + "</code> (domain_suffix: <code>" + escape_html(d) + "</code>)\n";
                text += "   " + t("test_action") + " <code>" + as_string(sec.action || "connection") + "</code>\n\n";
                matched = true;
            }
        }
        for (let d in domain) {
            if (target == d || target == "full:" + d) {
                text += "✅ " + t("test_match") + " <code>" + escape_html(sec[".name"]) + "</code> (domain: <code>" + escape_html(d) + "</code>)\n";
                text += "   " + t("test_action") + " <code>" + as_string(sec.action || "connection") + "</code>\n\n";
                matched = true;
            }
        }
        for (let kw in domain_keyword) {
            if (kw != "" && index(lc(target), lc(kw)) >= 0) {
                text += "✅ " + t("test_match") + " <code>" + escape_html(sec[".name"]) + "</code> (domain_keyword: <code>" + escape_html(kw) + "</code>)\n";
                text += "   " + t("test_action") + " <code>" + as_string(sec.action || "connection") + "</code>\n\n";
                matched = true;
            }
        }
        for (let ip in ip_cidr) {
            let norm_ip = (index(ip, "/") < 0 && match(ip, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)) ? (ip + "/32") : ip;
            if (match(target, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) && cidr_match_v4(target, norm_ip)) {
                text += "✅ " + t("test_match") + " <code>" + escape_html(sec[".name"]) + "</code> (ip_cidr: <code>" + escape_html(ip) + "</code>)\n";
                text += "   " + t("test_action") + " <code>" + as_string(sec.action || "connection") + "</code>\n\n";
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
    view_sec_conds,
    view_sec_bals,
    view_sec_grp,
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
    view_router_name,
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
