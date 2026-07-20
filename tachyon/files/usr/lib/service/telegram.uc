#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");
let common = require("core.common");
let api = require("service.api"); // Our new API module

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const PID_FILE = "/var/run/tachyon_telegram.pid";
const OFFSET_FILE = "/var/run/tachyon_telegram_offset";

let as_string = common.as_string;
let shell_quote = common.shell_quote;
let object_or_empty = common.object_or_empty;
let command_status = common.command_status;
let command_success_from_args = common.command_success_from_args;
let command_from_args = common.command_from_args;
let command_capture = common.command_capture;

// ─── Settings & Config ────────────────────────────────────────────────────────

function settings() {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
}

function get_proxy_args() {
    if (command_success_from_args(["pidof", "sing-box"])) {
        return [ "--proxy", "http://127.0.0.1:4534" ];
    }
    return [];
}

// ─── Telegram API Core ───────────────────────────────────────────────────────

function tg_request(token, method, payload) {
    if (!token) return null;
    let url = "https://api.telegram.org/bot" + token + "/" + method;
    let payload_path = "/tmp/tg_payload_" + method + "_" + time() + "_" + clock()[1] + ".json";
    
    let res = null;
    try {
        fs.writefile(payload_path, sprintf("%J", payload));
        let args = [ "curl", "-s", "-X", "POST", "-H", "Content-Type: application/json", "-d", "@" + payload_path ];
        let proxy = get_proxy_args();
        for (let p in proxy) push(args, p);
        push(args, url);
        res = command_capture(command_from_args(args));
    } catch (e) {
        try { fs.unlink(payload_path); } catch(err) {}
        return null;
    }
    try { fs.unlink(payload_path); } catch(err) {}
    
    if (!res || res.status != 0 || res.output == "") return null;
    try { return json(res.output); } catch (e) { return null; }
}

function send_message(token, chat_id, text, parse_mode, keyboard) {
    let payload = { chat_id: int(chat_id), text: text };
    if (parse_mode) payload.parse_mode = parse_mode;
    if (keyboard) payload.reply_markup = { inline_keyboard: keyboard };
    return tg_request(token, "sendMessage", payload);
}

function edit_message(token, chat_id, message_id, text, parse_mode, keyboard) {
    let payload = { chat_id: int(chat_id), message_id: int(message_id), text: text };
    if (parse_mode) payload.parse_mode = parse_mode;
    if (keyboard) payload.reply_markup = { inline_keyboard: keyboard };
    return tg_request(token, "editMessageText", payload);
}

// ─── State Management ────────────────────────────────────────────────────────

function get_tg_state(chat_id) {
    let f = "/tmp/tg_state_" + chat_id + ".json";
    let data = fs.readfile(f);
    if (data) { try { return json(data); } catch(e) {} }
    return null;
}

function set_tg_state(chat_id, state_obj) {
    let f = "/tmp/tg_state_" + chat_id + ".json";
    if (state_obj == null) fs.unlink(f);
    else fs.writefile(f, sprintf("%J", state_obj));
}

function is_admin(chat_id, admin_ids_str) {
    if (!admin_ids_str) return false;
    let admins = split(admin_ids_str, /,/);
    for (let admin in admins) {
        if (trim(admin) == as_string(chat_id)) return true;
    }
    return false;
}

function escape_html(text) {
    text = replace(as_string(text), /&/g, "&amp;");
    text = replace(text, /</g, "&lt;");
    text = replace(text, />/g, "&gt;");
    return text;
}

// ─── Views & Handlers ────────────────────────────────────────────────────────

function format_bytes(b) {
    b = double(b || 0);
    if (b > 1073741824) return sprintf("%.2f GB", b / 1073741824);
    if (b > 1048576) return sprintf("%.2f MB", b / 1048576);
    if (b > 1024) return sprintf("%.2f KB", b / 1024);
    return sprintf("%d B", b);
}

function view_menu(token, chat_id, msg_id) {
    let sys = api.get_system_status();
    let text = "🏠 <b>Tachyon Control Panel</b>\n\n" +
               "Версия: <code>" + sys.tachyon_version + "</code>\n" +
               "Роутер CPU: <code>" + sys.cpu + "</code>\n" +
               "Активный сервер: <code>" + escape_html(sys.active_server || "Не выбран") + "</code>\n\n" +
               "Выберите раздел для управления:";
               
    let keyboard = [
        [
            { text: "📊 Статус", callback_data: "/status" },
            { text: "🔍 Runtime", callback_data: "/runtime" }
        ],
        [
            { text: "🌐 Outbounds", callback_data: "/outbounds" },
            { text: "⚙️ Секции", callback_data: "/sections" }
        ],
        [
            { text: "💻 Устройства", callback_data: "/devices" },
            { text: "🐕 Watchdog", callback_data: "/watchdog" }
        ],
        [
            { text: "🩺 Диагностика", callback_data: "/doctor" },
            { text: "🔄 Перезапуск", callback_data: "/restart" }
        ]
    ];
    
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_status(token, chat_id, msg_id) {
    let sys = api.get_system_status();
    let text = "📊 <b>Статус Системы</b>\n\n" +
               "Аптайм: <code>" + sys.uptime + "</code>\n" +
               "CPU: <code>" + sys.cpu + "</code>\n" +
               "RAM: <code>" + sys.ram_avail + "MB free / " + sys.ram_total + "MB total</code>\n\n" +
               "sing-box: <code>" + sys.singbox + "</code>\n" +
               "Watchdog: <code>" + (sys.watchdog_running ? "🟢 running" : "🔴 stopped") + "</code>\n\n" +
               "WAN IP: <code>" + (sys.wan_ip || "unknown") + "</code>\n" +
               "LAN IP: <code>" + (sys.lan_ip || "unknown") + "</code>\n\n" +
               "Активный прокси: <code>" + escape_html(sys.active_server || "нет") + "</code>";
               
    if (sys.latency) text += " (" + sys.latency + " ms)";
    
    let keyboard = [
        [{ text: "🔄 Обновить", callback_data: "/status" }],
        [{ text: "⬅️ Назад", callback_data: "/menu" }]
    ];
    
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_runtime(token, chat_id, msg_id) {
    let data = api.get_clash_connections();
    let text = "🔍 <b>Runtime Info</b>\n\n";
    if (!data || data.downloadTotal == null) {
        text += "❌ Не удалось получить статистику соединений.";
    } else {
        text += "📥 Скачано: <code>" + format_bytes(data.downloadTotal) + "</code>\n" +
                "📤 Отдано: <code>" + format_bytes(data.uploadTotal) + "</code>\n" +
                "🧠 Память: <code>" + format_bytes(data.memory) + "</code>\n" +
                "🔗 Соединений: <code>" + length(data.connections || []) + "</code>\n";
    }
    
    let keyboard = [
        [{ text: "🔄 Обновить", callback_data: "/runtime" }],
        [{ text: "⬅️ Назад", callback_data: "/menu" }]
    ];
    
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_outbounds(token, chat_id, msg_id) {
    let data = api.get_clash_proxies_data();
    if (!data || !data.proxies) {
        let err = "❌ Не удалось получить список серверов.";
        if (msg_id) edit_message(token, chat_id, msg_id, err, "HTML", [[{text:"⬅️ Назад", callback_data:"/menu"}]]);
        else send_message(token, chat_id, err, "HTML", [[{text:"⬅️ Назад", callback_data:"/menu"}]]);
        return;
    }
    
    let active_server = "";
    let main_out = data.proxies["main-out"];
    if (main_out && main_out.now) active_server = main_out.now;
    
    let text = "🌐 <b>Outbounds (Серверы)</b>\n\n";
    let keyboard = [];
    let row = [];
    let count = 0;
    
    for (let name in keys(data.proxies)) {
        let proxy = data.proxies[name];
        let p_type = lc(as_string(proxy.type || ""));
        // Filter standard proxy types
        if (p_type == "vless" || p_type == "vmess" || p_type == "shadowsocks" || p_type == "trojan" || p_type == "socks" || p_type == "http" || p_type == "hysteria2" || p_type == "wireguard" || p_type == "hysteria") {
            let delay = "N/A";
            if (type(proxy.history) == "array" && length(proxy.history) > 0) {
                let last = proxy.history[length(proxy.history) - 1];
                if (last && last.delay) delay = last.delay + " ms";
            }
            let marker = (name == active_server) ? "🔵" : "•";
            text += marker + " <code>" + name + "</code>: <code>" + delay + "</code>\n";
            
            if (count < 18) {
                push(row, { text: (name == active_server ? "🔵 " : "") + name, callback_data: "/switch " + name });
                if (length(row) == 2) {
                    push(keyboard, row);
                    row = [];
                }
                count++;
            }
        }
    }
    if (length(row) > 0) push(keyboard, row);
    
    if (count == 0) text += "<i>Серверы не найдены.</i>\n";
    else text += "\nℹ️ Нажмите кнопку, чтобы переключить сервер.";
    
    push(keyboard, [{ text: "🔄 Обновить", callback_data: "/outbounds" }]);
    push(keyboard, [{ text: "⬅️ Назад", callback_data: "/menu" }]);
    
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function handle_switch(token, chat_id, msg_id, server_name) {
    api.clash_request("PUT", "proxies/main-out", { name: server_name });
    view_outbounds(token, chat_id, msg_id);
}


function view_sections(token, chat_id, msg_id) {
    let sections = api.get_sections();
    let text = "⚙️ <b>Секции Маршрутизации</b>\n\n";
    let keyboard = [];
    
    for (let s in sections) {
        let label = s.label || s[".name"];
        let status = (s.enabled == "1") ? "✅" : "❌";
        push(keyboard, [{ text: status + " " + label, callback_data: "/sec_view " + s[".name"] }]);
    }
    
    push(keyboard, [{ text: "➕ Создать секцию", callback_data: "/sec_create" }]);
    push(keyboard, [{ text: "⬅️ Назад", callback_data: "/menu" }]);
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_section_editor(token, chat_id, msg_id, sec_name) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let s = c.get_all(CONFIG_NAME, sec_name);
    if (!s) return view_sections(token, chat_id, msg_id);
    
    let status = (s.enabled == "1") ? "Включена ✅" : "Выключена ❌";
    let text = "⚙️ <b>Секция:</b> " + escape_html(s.label || sec_name) + "\n" +
               "Тип: <code>" + escape_html(s.action || "none") + "</code>\n" +
               "Статус: <b>" + status + "</b>\n\n";
               
    if (s.action == "proxy" || s.action == "route") {
        text += "Цель (Target): <code>" + escape_html(s.target || "main-out") + "</code>\n";
    }
    
    let d_count = length(common.list_option(s, "domain")) + length(common.list_option(s, "domain_suffix")) + length(common.list_option(s, "domain_keyword")) + length(common.list_option(s, "domain_regex"));
    let ip_count = length(common.list_option(s, "ip")) + length(common.list_option(s, "ip_cidr"));
    let src_count = length(common.list_option(s, "src_ip")) + length(common.list_option(s, "src_mac")) + length(common.list_option(s, "src_device"));
    let rs_count = length(common.list_option(s, "community_lists"));
               
    let keyboard = [];
    push(keyboard, [
        { text: (s.enabled == "1" ? "🔴 Выкл" : "🟢 Вкл"), callback_data: "/sec_toggle " + sec_name },
        { text: "✏️ Имя", callback_data: "/sec_rename " + sec_name }
    ]);
    
    push(keyboard, [{ text: "🔀 Действие: " + (s.action || "none"), callback_data: "/sec_action " + sec_name }]);
    if (s.action == "proxy" || s.action == "route") {
        push(keyboard, [{ text: "🌐 Цель: " + (s.target || "main-out"), callback_data: "/sec_target " + sec_name }]);
    }
    
    push(keyboard, [
        { text: "📝 Домены (" + d_count + ")", callback_data: "/sec_list " + sec_name + " domain" },
        { text: "📝 IP (" + ip_count + ")", callback_data: "/sec_list " + sec_name + " ip" }
    ]);
    push(keyboard, [
        { text: "📝 Источники (" + src_count + ")", callback_data: "/sec_list " + sec_name + " src" },
        { text: "📝 Rulesets (" + rs_count + ")", callback_data: "/sec_list " + sec_name + " ruleset" }
    ]);
    
    push(keyboard, [{ text: "🗑 Удалить секцию", callback_data: "/sec_delete " + sec_name }]);
    push(keyboard, [{ text: "🔙 К списку секций", callback_data: "/sections" }]);
    
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function handle_sec_toggle(token, chat_id, msg_id, sec_name) {
    api.toggle_section(sec_name);
    return view_section_editor(token, chat_id, msg_id, sec_name);
}

function handle_sec_action(token, chat_id, msg_id, sec_name) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let s = c.get_all(CONFIG_NAME, sec_name);
    if (!s) return;
    let acts = ["proxy", "bypass", "block", "connection"];
    let idx = -1;
    for (let i = 0; i < length(acts); i++) { if (acts[i] == s.action) idx = i; }
    if (idx == -1) push(acts, s.action);
    let next_act = acts[(idx + 1) % length(acts)];
    c.set(CONFIG_NAME, sec_name, "action", next_act);
    c.commit(CONFIG_NAME);
    return view_section_editor(token, chat_id, msg_id, sec_name);
}

function view_sec_list(token, chat_id, msg_id, sec_name, list_type) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let s = c.get_all(CONFIG_NAME, sec_name);
    if (!s) return;
    
    let items = [];
    let title = "";
    if (list_type == "domain") {
        title = "Домены";
        let ds = common.list_option(s, "domain_suffix");
        for (let x in ds) push(items, {type: "domain_suffix", val: x});
        let d = common.list_option(s, "domain");
        for (let x in d) push(items, {type: "domain", val: x});
        let dk = common.list_option(s, "domain_keyword");
        for (let x in dk) push(items, {type: "domain_keyword", val: x});
        let dr = common.list_option(s, "domain_regex");
        for (let x in dr) push(items, {type: "domain_regex", val: x});
    } else if (list_type == "ip") {
        title = "IP адреса";
        let ipc = common.list_option(s, "ip_cidr");
        for (let x in ipc) push(items, {type: "ip_cidr", val: x});
        let ip = common.list_option(s, "ip");
        for (let x in ip) push(items, {type: "ip", val: x});
    } else if (list_type == "src") {
        title = "Источники (Source)";
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
    
    let text = "⚙️ <b>Секция:</b> " + escape_html(s.label || sec_name) + "\n" +
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
                push(keyboard, [{ text: "❌ Удалить " + it.val, callback_data: "/sec_del_it " + sec_name + " " + it.type + " " + it.val }]);
            }
        }
        if (length(items) > 20) text += "\n<i>(Показаны не все элементы для удаления)</i>\n";
    }
    
    push(keyboard, [
        { text: "➕ Добавить", callback_data: "/sec_add " + sec_name + " " + list_type },
        { text: "➖ Очистить все", callback_data: "/sec_clear " + sec_name + " " + list_type }
    ]);
    push(keyboard, [{ text: "🔙 Назад к секции", callback_data: "/sec_view " + sec_name }]);
    
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function handle_sec_del_it(token, chat_id, msg_id, sec_name, type, val) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let s = c.get_all(CONFIG_NAME, sec_name);
    if (!s) return;
    
    let current = common.list_option(s, type);
    let new_list = [];
    for (let x in current) if (x != val) push(new_list, x);
    
    c.set(CONFIG_NAME, sec_name, type, new_list);
    c.commit(CONFIG_NAME);
    
    // figure out parent list_type
    let list_type = "domain";
    if (match(type, /^ip/)) list_type = "ip";
    else if (match(type, /^src/)) list_type = "src";
    else if (type == "community_lists") list_type = "ruleset";
    
    return view_sec_list(token, chat_id, msg_id, sec_name, list_type);
}

function handle_sec_clear(token, chat_id, msg_id, sec_name, list_type) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let s = c.get_all(CONFIG_NAME, sec_name);
    if (!s) return;
    
    let keys = [];
    if (list_type == "domain") keys = ["domain", "domain_suffix", "domain_keyword", "domain_regex"];
    else if (list_type == "ip") keys = ["ip", "ip_cidr"];
    else if (list_type == "src") keys = ["src_ip", "src_mac", "src_device"];
    else if (list_type == "ruleset") keys = ["community_lists"];
    
    for (let k in keys) {
        c.delete(CONFIG_NAME, sec_name, k);
    }
    c.commit(CONFIG_NAME);
    return view_sec_list(token, chat_id, msg_id, sec_name, list_type);
}

function exec_doctor(token, chat_id) {
    send_message(token, chat_id, "⏳ <b>Запуск диагностики и авто-исправления...</b>", "HTML");
    let res = command_capture("/usr/bin/tachyon doctor");
    let report = res.output || "Нет вывода диагностики.";
    send_message(token, chat_id, "🩺 <b>Результаты Tachyon Doctor:</b>\n\n<pre>" + escape_html(report) + "</pre>", "HTML", [[{text:"⬅️ Назад", callback_data:"/menu"}]]);
}

function exec_restart(token, chat_id) {
    send_message(token, chat_id, "🔄 <b>Перезапускаю службы Tachyon...</b>", "HTML");
    let st = command_status("/usr/bin/tachyon restart");
    if (st == 0) send_message(token, chat_id, "✅ <b>Перезапуск выполнен успешно!</b>", "HTML", [[{text:"⬅️ Меню", callback_data:"/menu"}]]);
    else send_message(token, chat_id, "❌ <b>Ошибка при перезапуске.</b>", "HTML", [[{text:"⬅️ Меню", callback_data:"/menu"}]]);
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
    
    let text = "💻 <b>Устройства в сети:</b>\n\n";
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
            let hostname = fields[3] == "*" ? "Неизвестно" : fields[3];
            
            let is_blocked = blocked_macs[mac] ? true : false;
            let status_icon = is_blocked ? "🚫" : "🟢";
            
            text += status_icon + " <b>" + escape_html(hostname) + "</b>\n";
            text += "└ IP: <code>" + ip + "</code> | MAC: <code>" + mac + "</code>\n\n";
            
            push(keyboard, [{ text: (is_blocked ? "🔓 Разблокировать " : "🚫 Заблокировать ") + hostname, callback_data: "/toggle_mac " + mac }]);
            count++;
        }
    }
    
    if (count == 0) text += "<i>Устройства не найдены.</i>\n";
    
    push(keyboard, [{ text: "🔄 Обновить", callback_data: "/devices" }]);
    push(keyboard, [{ text: "⬅️ Назад", callback_data: "/menu" }]);
    
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_watchdog(token, chat_id, msg_id) {
    let running = api.process_running_by_pidfile("/var/run/tachyon_watchdog.pid");
    let text = "🐕 <b>Watchdog Tachyon</b>\n\n" +
               "Статус: <code>" + (running ? "🟢 Запущен" : "🔴 Остановлен") + "</code>";
               
    let keyboard = [];
    if (running) {
        push(keyboard, [{ text: "⏹️ Остановить Watchdog", callback_data: "/wd_stop" }]);
    } else {
        push(keyboard, [{ text: "▶️ Запустить Watchdog", callback_data: "/wd_start" }]);
    }
    push(keyboard, [{ text: "⬅️ Назад", callback_data: "/menu" }]);
    
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

// ─── Dispatcher ──────────────────────────────────────────────────────────────

function dispatch_command(token, chat_id, text, msg_id) {
    let cmd = trim(as_string(text));
    let state = get_tg_state(chat_id);
    
    if (cmd == "/start" || cmd == "/menu") return view_menu(token, chat_id, msg_id);
    if (cmd == "/status") return view_status(token, chat_id, msg_id);
    if (cmd == "/runtime") return view_runtime(token, chat_id, msg_id);
    if (cmd == "/outbounds") return view_outbounds(token, chat_id, msg_id);
    if (cmd == "/sections") return view_sections(token, chat_id, msg_id);
    if (cmd == "/devices") return view_devices(token, chat_id, msg_id);
    if (cmd == "/watchdog") return view_watchdog(token, chat_id, msg_id);
    if (cmd == "/doctor") return exec_doctor(token, chat_id);
    if (cmd == "/restart") return exec_restart(token, chat_id);
    
    if (cmd == "/wd_start") {
        command_status("/usr/bin/tachyon watchdog_start");
        return view_watchdog(token, chat_id, msg_id);
    }
    if (cmd == "/wd_stop") {
        command_status("/usr/bin/tachyon watchdog_stop");
        return view_watchdog(token, chat_id, msg_id);
    }
    
    // Commands with args
    
    if (match(cmd, /^\/sec_create/)) {
        set_tg_state(chat_id, { action: "sec_create" });
        return send_message(token, chat_id, "📝 Введите латинское имя для новой секции (например, <code>my_vpn</code>):\n\n<i>Отправьте /cancel для отмены</i>", "HTML");
    }
    if (match(cmd, /^\/sec_rename /)) {
        let sec = trim(substr(cmd, 12));
        set_tg_state(chat_id, { action: "sec_rename", sec: sec });
        return send_message(token, chat_id, "📝 Введите новое понятное имя (Label) для секции <code>" + sec + "</code>:\n\n<i>Отправьте /cancel для отмены</i>", "HTML");
    }
    if (match(cmd, /^\/sec_target /)) {
        let sec = trim(substr(cmd, 12));
        set_tg_state(chat_id, { action: "sec_target", sec: sec });
        return send_message(token, chat_id, "🌐 Введите имя исходящего интерфейса (target) для секции <code>" + sec + "</code> (например, <code>main-out</code> или <code>direct-out</code>):\n\n<i>Отправьте /cancel для отмены</i>", "HTML");
    }
    if (match(cmd, /^\/sec_action /)) {
        let sec = trim(substr(cmd, 12));
        return handle_sec_action(token, chat_id, msg_id, sec);
    }
    if (match(cmd, /^\/sec_delete /)) {
        let sec = trim(substr(cmd, 12));
        let c = uci_core.cursor();
        c.load(CONFIG_NAME);
        c.delete(CONFIG_NAME, sec);
        c.commit(CONFIG_NAME);
        send_message(token, chat_id, "✅ Секция <code>" + sec + "</code> удалена.", "HTML");
        return view_sections(token, chat_id, null);
    }
    if (match(cmd, /^\/sec_list /)) {
        let parts = split(trim(substr(cmd, 10)), " ");
        if (length(parts) == 2) return view_sec_list(token, chat_id, msg_id, parts[0], parts[1]);
    }
    if (match(cmd, /^\/sec_add /)) {
        let parts = split(trim(substr(cmd, 9)), " ");
        if (length(parts) == 2) {
            set_tg_state(chat_id, { action: "sec_add", sec: parts[0], list: parts[1] });
            return send_message(token, chat_id, "➕ Отправьте элементы для добавления (по одному в строке или через пробел):\n\n<i>Отправьте /cancel для отмены</i>", "HTML");
        }
    }
    if (match(cmd, /^\/sec_clear /)) {
        let parts = split(trim(substr(cmd, 11)), " ");
        if (length(parts) == 2) return handle_sec_clear(token, chat_id, msg_id, parts[0], parts[1]);
    }
    if (match(cmd, /^\/sec_del_it /)) {
        let parts = split(trim(substr(cmd, 12)), " ");
        if (length(parts) >= 3) {
            let sec = parts[0];
            let type = parts[1];
            let val = join(" ", slice(parts, 2));
            return handle_sec_del_it(token, chat_id, msg_id, sec, type, val);
        }
    }
    if (match(cmd, /^\/sec_view /)) {
        let sec = trim(substr(cmd, 10));
        return view_section_editor(token, chat_id, msg_id, sec);
    }
    if (match(cmd, /^\/sec_toggle /)) {
        let sec = trim(substr(cmd, 12));
        return handle_sec_toggle(token, chat_id, msg_id, sec);
    }

    if (match(cmd, /^\/switch /)) {
        let srv = trim(substr(cmd, 8));
        return handle_switch(token, chat_id, msg_id, srv);
    }
    
    if (match(cmd, /^\/sec_view /)) {
        let sec = trim(substr(cmd, 10));
        return view_section_detail(token, chat_id, msg_id, sec);
    }
    
    if (match(cmd, /^\/sec_toggle /)) {
        let sec = trim(substr(cmd, 12));
        api.toggle_section(sec);
        return view_section_detail(token, chat_id, msg_id, sec);
    }
    
    // Default / Help
    if (!msg_id) {
        view_menu(token, chat_id, null);
    }
}

function process_updates(token, admin_ids) {
    let offset = int(trim(fs.readfile(OFFSET_FILE) || "0"));
    let res = tg_request(token, "getUpdates", { offset: offset, timeout: 20 });
    
    if (!res || !res.ok || !res.result || length(res.result) == 0) return;
    
    for (let upd in res.result) {
        let update_id = upd.update_id;
        if (update_id >= offset) {
            offset = update_id + 1;
            fs.writefile(OFFSET_FILE, as_string(offset));
        }
        
        let cb = upd.callback_query;
        if (cb) {
            let chat_id = cb.message ? cb.message.chat.id : cb.from.id;
            if (!is_admin(chat_id, admin_ids)) {
                tg_request(token, "answerCallbackQuery", { callback_query_id: cb.id, text: "Access Denied" });
                continue;
            }
            dispatch_command(token, chat_id, cb.data, cb.message.message_id);
            tg_request(token, "answerCallbackQuery", { callback_query_id: cb.id });
            continue;
        }
        
        let msg = upd.message;
        if (msg && msg.text) {
            let chat_id = msg.chat.id;
            if (!is_admin(chat_id, admin_ids)) {
                send_message(token, chat_id, "❌ Доступ запрещен. Ваш Chat ID: `" + chat_id + "`", "Markdown");
                continue;
            }
            
            if (msg.text == "/cancel") {
                set_tg_state(chat_id, null);
                send_message(token, chat_id, "❌ Действие отменено.", "HTML", [[{text:"⬅️ Меню", callback_data:"/menu"}]]);
                continue;
            }
            
            let state = get_tg_state(chat_id);
            if (state) {
                // handle state
                set_tg_state(chat_id, null); // clear immediately
                let c = uci_core.cursor();
                c.load(CONFIG_NAME);
                
                if (state.action == "sec_create") {
                    let new_sec = trim(msg.text);
                    if (match(new_sec, /^[a-zA-Z0-9_]+$/)) {
                        c.set(CONFIG_NAME, new_sec, "section");
                        c.set(CONFIG_NAME, new_sec, "action", "proxy");
                        c.set(CONFIG_NAME, new_sec, "enabled", "1");
                        c.set(CONFIG_NAME, new_sec, "label", new_sec);
                        c.commit(CONFIG_NAME);
                        send_message(token, chat_id, "✅ Секция создана!");
                        view_section_editor(token, chat_id, null, new_sec);
                    } else {
                        send_message(token, chat_id, "❌ Неверное имя. Разрешены только буквы, цифры и подчеркивания.");
                    }
                }
                else if (state.action == "sec_rename") {
                    let new_label = trim(msg.text);
                    c.set(CONFIG_NAME, state.sec, "label", new_label);
                    c.commit(CONFIG_NAME);
                    send_message(token, chat_id, "✅ Имя изменено.");
                    view_section_editor(token, chat_id, null, state.sec);
                }
                else if (state.action == "sec_target") {
                    let new_target = trim(msg.text);
                    c.set(CONFIG_NAME, state.sec, "target", new_target);
                    c.commit(CONFIG_NAME);
                    send_message(token, chat_id, "✅ Цель изменена.");
                    view_section_editor(token, chat_id, null, state.sec);
                }
                else if (state.action == "sec_add") {
                    let items = split(trim(msg.text), /[ \n,;]+/);
                    let valid_items = [];
                    for (let x in items) if (trim(x) != "") push(valid_items, trim(x));
                    
                    if (length(valid_items) > 0) {
                        let field = "domain_suffix";
                        if (state.list == "ip") field = "ip_cidr";
                        else if (state.list == "src") field = "src_ip";
                        else if (state.list == "ruleset") field = "community_lists";
                        
                        let current = common.list_option(c.get_all(CONFIG_NAME, state.sec), field);
                        for (let x in valid_items) push(current, x);
                        c.set(CONFIG_NAME, state.sec, field, current);
                        c.commit(CONFIG_NAME);
                        send_message(token, chat_id, "✅ Добавлено " + length(valid_items) + " элементов.");
                    } else {
                        send_message(token, chat_id, "❌ Ничего не добавлено.");
                    }
                    view_sec_list(token, chat_id, null, state.sec, state.list);
                }
                continue;
            }

            dispatch_command(token, chat_id, msg.text, null);
        }
    }
}

// ─── Entry Point ─────────────────────────────────────────────────────────────

function worker() {
    let cfg = settings();
    if (cfg.enabled != "1" || !cfg.bot_token) return 0;

    let commands = [
        { command: "menu",      description: "Main Menu" },
        { command: "status",    description: "System status" },
        { command: "runtime",   description: "Runtime stats" },
        { command: "outbounds", description: "Proxy servers" },
        { command: "sections",  description: "Routing sections" },
        { command: "doctor",    description: "Diagnostics" },
        { command: "restart",   description: "Restart router" }
    ];
    tg_request(cfg.bot_token, "setMyCommands", { commands: commands });

    let poll_interval = int(cfg.poll_interval || "5");
    if (poll_interval < 1) poll_interval = 1;

    while (true) {
        cfg = settings();
        if (cfg.enabled != "1") break;
        process_updates(cfg.bot_token, cfg.admin_ids);
        sleep(poll_interval * 1000);
    }
    return 0;
}

function stop_runtime() {
    let pid = trim(fs.readfile(PID_FILE) || "");
    if (pid != "" && match(pid, /^[0-9]+$/) != null && command_success_from_args([ "kill", "-0", pid ])) {
        command_success_from_args([ "kill", "-9", pid ]);
    }
    fs.unlink(PID_FILE);
    return 0;
}

function start_runtime() {
    let cfg = settings();
    stop_runtime();
    if (cfg.enabled != "1" || !cfg.bot_token) return 0;
    
    let command = command_from_args([ "ucode", "-L", LIB_DIR, LIB_DIR + "/service/telegram.uc", "worker" ]) +
        " </dev/null >/var/log/tachyon_telegram.log 2>&1 1000<&- & echo $! >" + shell_quote(PID_FILE);
    return command_status(command);
}

function get_status() {
    let pid = trim(fs.readfile(PID_FILE) || "");
    if (pid != "" && match(pid, /^[0-9]+$/) != null && command_success_from_args([ "kill", "-0", pid ])) {
        print("running (pid " + pid + ")\n");
        return 0;
    }
    print("stopped\n");
    return 1;
}

function send_api(message) {
    let cfg = settings();
    if (cfg.enabled != "1" || !cfg.bot_token || !cfg.admin_ids) return 1;
    let admins = split(cfg.admin_ids, /,/);
    for (let admin in admins) {
        let chat_id = trim(admin);
        if (chat_id != "") send_message(cfg.bot_token, chat_id, message, "Markdown", null);
    }
    return 0;
}

let mode = (ARGV[0] == "") ? ARGV[1] : ARGV[0];
if (!mode) mode = "";

if (mode == "start-runtime")
    exit(start_runtime());
else if (mode == "stop-runtime")
    exit(stop_runtime());
else if (mode == "worker")
    exit(worker());
else if (mode == "status")
    exit(get_status());
else if (mode != "") {
    warn("Usage: service/telegram.uc <start-runtime|stop-runtime|worker|status> ...\n");
    exit(1);
}
