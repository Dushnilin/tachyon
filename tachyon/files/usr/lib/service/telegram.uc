#!/usr/bin/env ucode
 
let fs = require("fs");
let uci_core = require("core.uci");
let common = require("core.common");
 
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

 
 
 
 
function command_capture(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return { status: 1, output: "" };
 
    let data = pipe.read("all");
    let status = pipe.close();
    status = status > 255 ? int(status / 256) : status;
    return { status, output: data == null ? "" : as_string(data) };
}
 
function settings() {
    return common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
}
 
function get_proxy_args() {
    if (command_success_from_args(["pidof", "sing-box"])) {
        return [ "--proxy", "http://127.0.0.1:4534" ];
    }
    return [];
}
 
function tg_request(token, method, payload) {
    if (!token) return null;
    let url = "https://api.telegram.org/bot" + token + "/" + method;
    let payload_path = "/tmp/tg_payload_" + method + "_" + time() + "_" + clock()[1] + ".json";
    
    let res = null;
    try {
        fs.writefile(payload_path, sprintf("%J", payload));
        
        let args = [ "curl", "-s", "-X", "POST", "-H", "Content-Type: application/json", "-d", "@" + payload_path ];
        let proxy = get_proxy_args();
        for (let p in proxy) {
            push(args, p);
        }
        push(args, url);
        
        res = command_capture(command_from_args(args));
    }
    catch (e) {
        try { fs.unlink(payload_path); } catch(err) {}
        return null;
    }
    
    try { fs.unlink(payload_path); } catch(err) {}
    
    if (!res || res.status != 0 || res.output == "") {
        return null;
    }
    
    try {
        return json(res.output);
    }
    catch (e) {
        return null;
    }
}
 
function clash_request(method, endpoint, payload) {
    let url = get_clash_url(endpoint);
    let payload_path = "/tmp/clash_payload_" + method + "_" + time() + "_" + clock()[1] + ".json";
    let res = null;
    try {
        let args = [ "curl", "-s", "-X", method ];
        if (payload) {
            fs.writefile(payload_path, sprintf("%J", payload));
            push(args, "-H", "Content-Type: application/json", "-d", "@" + payload_path);
        }
        push(args, url);
        res = command_capture(command_from_args(args));
    }
    catch (e) {
        if (payload) {
            try { fs.unlink(payload_path); } catch(err) {}
        }
        return null;
    }
    
    if (payload) {
        try { fs.unlink(payload_path); } catch(err) {}
    }
    
    if (!res || res.status != 0 || res.output == "") {
        return null;
    }
    
    try {
        return json(res.output);
    }
    catch (e) {
        return res.output;
    }
}

function send_message(token, chat_id, text, parse_mode) {
    let payload = {
        chat_id: int(chat_id),
        text: text
    };
    if (parse_mode) {
        payload.parse_mode = parse_mode;
    }
    return tg_request(token, "sendMessage", payload);
}
 
function send_message_with_keyboard(token, chat_id, text, parse_mode) {
    let payload = {
        chat_id: int(chat_id),
        text: text,
        reply_markup: {
            inline_keyboard: [
                [
                    { text: "📡 Серверы", callback_data: "/servers" },
                    { text: "🛡️ Правила", callback_data: "/rules" },
                    { text: "💻 Устройства", callback_data: "/devices" }
                ],
                [
                    { text: "🚀 Скорость", callback_data: "/speed" },
                    { text: "📊 Трафик", callback_data: "/traffic" },
                    { text: "🩺 Диагностика", callback_data: "/doctor" }
                ]
            ]
        }
    };
    if (parse_mode) {
        payload.parse_mode = parse_mode;
    }
    return tg_request(token, "sendMessage", payload);
}
 
function is_admin(chat_id, admin_ids_str) {
    if (!admin_ids_str) return false;
    let admins = split(admin_ids_str, /,/);
    for (let admin in admins) {
        if (trim(admin) == as_string(chat_id)) return true;
    }
    return false;
}
 
function get_system_status() {
    let status_obj = {};
    
    // CPU
    let stat = fs.readfile("/proc/loadavg") || "";
    let load = split(stat, / /);
    status_obj.cpu = (length(load) > 0) ? load[0] : "unknown";
    
    // RAM
    let mem = fs.readfile("/proc/meminfo") || "";
    let total_kb = 0, avail_kb = 0;
    for (let line in split(mem, "\n")) {
        if (index(line, "MemTotal:") == 0) {
            total_kb = int(split(trim(line), /[ \t]+/)[1]);
        }
        else if (index(line, "MemAvailable:") == 0) {
            avail_kb = int(split(trim(line), /[ \t]+/)[1]);
        }
    }
    status_obj.ram_total = total_kb ? int(total_kb / 1024) : 0;
    status_obj.ram_avail = avail_kb ? int(avail_kb / 1024) : 0;
    
    // Uptime
    let upt = fs.readfile("/proc/uptime") || "";
    let up_sec = double(split(upt, / /)[0] || 0);
    let d = int(up_sec / 86400);
    let h = int((up_sec - (d * 86400)) / 3600);
    let m = int((up_sec - (d * 86400) - (h * 3600)) / 60);
    status_obj.uptime = sprintf("%d дн. %02d:%02d", d, h, m);
    
    // sing-box status
    let sb_running = command_success_from_args(["pidof", "sing-box"]);
    status_obj.singbox = sb_running ? "🟢 running" : "🔴 stopped";
    
    return status_obj;
}
 
function format_bytes(b) {
    b = double(b || 0);
    if (b > 1073741824) return sprintf("%.2f GB", b / 1073741824);
    if (b > 1048576) return sprintf("%.2f MB", b / 1048576);
    if (b > 1024) return sprintf("%.2f KB", b / 1024);
    return sprintf("%d B", b);
}
 
function get_clash_url(endpoint) {
    let host = "127.0.0.1:9090"; // default fallback
    let config_data = fs.readfile("/etc/sing-box/config.json");
    if (config_data) {
        try {
            let sb_cfg = json(config_data);
            let ext = sb_cfg.experimental?.clash_api?.external_controller;
            if (ext) {
                let parts = split(ext, ":");
                let port = (length(parts) > 1) ? parts[length(parts) - 1] : "9090";
                host = "127.0.0.1:" + port;
            }
        } catch(e) {}
    }
    return "http://" + host + "/" + endpoint;
}

function get_clash_proxies_data() {
    let args = [ "curl", "-s", get_clash_url("proxies") ];
    let res = command_capture(command_from_args(args));
    if (res.status == 0 && res.output != "") {
        try {
            return json(res.output);
        } catch (e) {}
    }
    return null;
}
 
function check_connection() {
    let res_direct = command_capture("curl -I -s --connect-timeout 5 https://www.google.com");
    let direct_ok = (res_direct.status == 0) ? "🟢 OK" : "🔴 FAIL";
    
    let res_proxy = command_capture("curl -I -s --connect-timeout 5 --proxy http://127.0.0.1:4534 https://www.google.com");
    let proxy_ok = (res_proxy.status == 0) ? "🟢 OK" : "🔴 FAIL";
    
    return { direct: direct_ok, proxy: proxy_ok };
}
 
function handle_servers(token, chat_id) {
    let data = get_clash_proxies_data();
    if (!data || !data.proxies) {
        send_message_with_keyboard(token, chat_id, "❌ Не удалось получить список серверов из sing-box API.");
        return;
    }
    
    let active_server = "Не определен";
    let main_out = data.proxies["main-out"];
    if (main_out && main_out.now) {
        active_server = main_out.now;
    }
    
    let text = "📡 *Список серверов и задержка:*\n\n";
    let count = 0;
    
    let keyboard = [];
    let row = [];
    let btn_count = 0;
    
    for (let name in keys(data.proxies)) {
        let proxy = data.proxies[name];
        let p_type = lc(as_string(proxy.type || ""));
        if (p_type == "vless" || p_type == "vmess" || p_type == "shadowsocks" || p_type == "trojan" || p_type == "socks" || p_type == "http" || p_type == "hysteria2" || p_type == "tuic" || p_type == "wireguard" || p_type == "hysteria" || p_type == "ssr") {
            let delay = "N/A";
            if (type(proxy.history) == "array" && length(proxy.history) > 0) {
                let last = proxy.history[length(proxy.history) - 1];
                if (last && last.delay) {
                    delay = last.delay + " ms";
                }
            }
            let marker = (name == active_server) ? "🔵" : "•";
            text += marker + " `" + name + "`: `" + delay + "`\n";
            count++;
            
            if (btn_count < 18) {
                push(row, { text: (name == active_server ? "🔵 " : "") + name, callback_data: "/switch " + name });
                if (length(row) == 2) {
                    push(keyboard, row);
                    row = [];
                }
                btn_count++;
            }
        }
    }
    
    if (length(row) > 0) {
        push(keyboard, row);
    }
    
    if (count == 0) {
        text += "_Серверы не найдены._\n";
    } else {
        text += "\nℹ️ Активный сервер: *" + active_server + "*";
    }
    
    push(keyboard, [ { text: "⬅️ Назад в меню", callback_data: "/help" } ]);
    
    let payload = {
        chat_id: int(chat_id),
        text: text,
        parse_mode: "Markdown",
        reply_markup: { inline_keyboard: keyboard }
    };
    tg_request(token, "sendMessage", payload);
}
 
function handle_traffic(token, chat_id) {
    let args = [ "curl", "-s", get_clash_url("connections") ];
    let res = command_capture(command_from_args(args));
    if (res.status != 0 || res.output == "") {
        send_message_with_keyboard(token, chat_id, "❌ Не удалось получить статистику трафика.");
        return;
    }
    
    let data = null;
    try {
        data = json(res.output);
    } catch (e) {}
    
    if (!data || data.downloadTotal == null) {
        send_message_with_keyboard(token, chat_id, "❌ Ошибка разбора статистики трафика.");
        return;
    }
    
    let dl = format_bytes(data.downloadTotal);
    let ul = format_bytes(data.uploadTotal);
    let memory_used = format_bytes(data.memory);
    
    let text = "📊 *Статистика трафика sing-box:*\n\n" +
        "📥 Всего скачано: `" + dl + "`\n" +
        "📤 Всего отдано: `" + ul + "`\n" +
        "🧠 Память sing-box: `" + memory_used + "`";
        
    send_message_with_keyboard(token, chat_id, text, "Markdown");
}
 
function handle_test(token, chat_id) {
    send_message(token, chat_id, "⏳ *Проверка интернет-соединения...*");
    
    let conn = check_connection();
    let text = "📡 *Результаты проверки соединения:*\n\n" +
        "🌐 Прямой доступ: " + conn.direct + "\n" +
        "🛡️ Доступ через прокси: " + conn.proxy;
        
    send_message_with_keyboard(token, chat_id, text, "Markdown");
}
 
function run_speedtest(token, chat_id) {
    send_message(token, chat_id, "🚀 *Запуск теста скорости (5MB)...*");
    
    // Direct speedtest
    let res_direct = command_capture("curl -s -w '%{speed_download}' -o /dev/null --connect-timeout 8 https://speed.cloudflare.com/__down?bytes=5242880");
    let direct_speed = double(res_direct.output || 0);
    let direct_mbps = (direct_speed * 8) / 1000000;
    
    // Proxy speedtest
    let res_proxy = command_capture("curl -s -w '%{speed_download}' -o /dev/null --connect-timeout 8 --proxy http://127.0.0.1:4534 https://speed.cloudflare.com/__down?bytes=5242880");
    let proxy_speed = double(res_proxy.output || 0);
    let proxy_mbps = (proxy_speed * 8) / 1000000;
    
    let result_text = "🚀 *Результаты теста скорости (5MB):*\n\n" +
        "⚡ Прямое соединение: `" + sprintf("%.2f", direct_mbps) + " Mbps`\n" +
        "🛡️ Через прокси: `" + sprintf("%.2f", proxy_mbps) + " Mbps`";
        
    send_message_with_keyboard(token, chat_id, result_text, "Markdown");
}
 
function escape_html(text) {
    text = replace(as_string(text), /&/g, "&amp;");
    text = replace(text, /</g, "&lt;");
    text = replace(text, />/g, "&gt;");
    return text;
}

function manage_domain_list(action_type, domain, do_delete) {
    let c = uci_core.cursor();
    if (!c) return { success: false, error: "Не удалось инициализировать UCI" };
    c.load(CONFIG_NAME);

    let target_section = null;
    c.foreach(CONFIG_NAME, "section", function(s) {
        if (s.enabled == "1" && s.action == action_type) {
            target_section = s[".name"];
            return false;
        }
    });

    if (!target_section) {
        return { success: false, error: "Не найдено активное правило с действием '" + action_type + "'." };
    }

    let option_path = CONFIG_NAME + "." + target_section + ".domain";

    if (do_delete) {
        let deleted = uci_core.del_list(option_path, domain);
        if (deleted) {
            uci_core.commit(CONFIG_NAME);
            command_status("/usr/bin/tachyon reload");
            return { success: true, message: "Домен `" + domain + "` успешно удален из правила." };
        } else {
            return { success: false, error: "Домен `" + domain + "` не найден в правиле." };
        }
    } else {
        let current_val = uci_core.get(option_path);
        let exists = false;
        if (current_val != "") {
            for (let item in split(current_val, " ")) {
                if (item == domain) {
                    exists = true;
                    break;
                }
            }
        }
        if (exists) {
            return { success: false, error: "Домен `" + domain + "` уже есть в правиле." };
        }

        let added = uci_core.add_list(option_path, domain);
        if (added) {
            uci_core.commit(CONFIG_NAME);
            command_status("/usr/bin/tachyon reload");
            return { success: true, message: "Домен `" + domain + "` успешно добавлен в правило." };
        }
        return { success: false, error: "Не удалось добавить домен в конфигурацию." };
    }
}

function manage_mac_block(mac, do_unblock) {
    let c = uci_core.cursor();
    if (!c) return { success: false, error: "Не удалось инициализировать UCI" };
    c.load("firewall");

    mac = uc(as_string(mac));

    if (do_unblock) {
        let deleted = false;
        c.foreach("firewall", "rule", function(r) {
            if (uc(as_string(r.src_mac)) == mac && r.target == "REJECT") {
                c.delete("firewall", r[".name"]);
                deleted = true;
            }
        });

        if (deleted) {
            c.commit("firewall");
            command_status("/etc/init.d/firewall reload");
            return { success: true, message: "Блокировка с MAC-адреса `" + mac + "` успешно снята." };
        }
        return { success: false, error: "Блокировка для MAC `" + mac + "` не найдена." };
    } else {
        let exists = false;
        c.foreach("firewall", "rule", function(r) {
            if (uc(as_string(r.src_mac)) == mac && r.target == "REJECT") {
                exists = true;
                return false;
            }
        });

        if (exists) {
            return { success: false, error: "Устройство с MAC `" + mac + "` уже заблокировано." };
        }

        let section = c.add("firewall", "rule");
        c.set("firewall", section, "name", "Block_MAC_" + replace(mac, /:/g, "_"));
        c.set("firewall", section, "src", "lan");
        c.set("firewall", section, "dest", "*");
        c.set("firewall", section, "src_mac", mac);
        c.set("firewall", section, "target", "REJECT");
        c.commit("firewall");

        command_status("/etc/init.d/firewall reload");
        return { success: true, message: "Устройство с MAC `" + mac + "` успешно заблокировано." };
    }
}

function handle_backup(token, chat_id) {
    send_message(token, chat_id, "⏳ <b>Создание резервной копии настроек...</b>", "HTML");
    
    let backup_path = "/tmp/tachyon_backup.tar.gz";
    let tar_cmd = "tar -czf " + backup_path + " -C /etc config/ -C /usr/lib/tachyon/ providers/";
    let res = command_capture(tar_cmd);
    
    if (res.status != 0 || fs.stat(backup_path) == null) {
        send_message(token, chat_id, "❌ Не удалось создать архив резервной копии.", "HTML");
        return;
    }
    
    let url = "https://api.telegram.org/bot" + token + "/sendDocument";
    let args = [
        "curl", "-s", "-X", "POST",
        "-F", "chat_id=" + as_string(chat_id),
        "-F", "document=@" + backup_path
    ];
    let proxy = get_proxy_args();
    for (let p in proxy) {
        push(args, p);
    }
    push(args, url);
    
    let send_res = command_capture(command_from_args(args));
    fs.unlink(backup_path);
    
    if (send_res.status == 0) {
        send_message(token, chat_id, "✅ Резервная копия успешно отправлена!", "HTML");
    } else {
        send_message(token, chat_id, "❌ Ошибка при отправке файла резервной копии.", "HTML");
    }
}

function handle_rules(token, chat_id) {
    let c = uci_core.cursor();
    if (!c) {
        send_message(token, chat_id, "❌ Не удалось прочитать конфигурацию.");
        return;
    }
    c.load(CONFIG_NAME);
    
    let text = "🛡️ <b>Управление правилами обхода:</b>\n\n";
    let keyboard = [];
    let count = 0;
    
    c.foreach(CONFIG_NAME, "section", function(s) {
        let name = s[".name"];
        let label = s.label || name;
        let enabled = s.enabled != "0";
        let status_icon = enabled ? "🟢" : "🔴";
        let action = s.action || "bypass";
        
        text += status_icon + " <b>" + escape_html(label) + "</b> (" + action + ")\n";
        
        push(keyboard, [
            {
                text: (enabled ? "🔴 Выключить " : "🟢 Включить ") + label,
                callback_data: "/toggle_rule " + name
            }
        ]);
        count++;
    });
    
    if (count == 0) {
        text += "<i>Правила отсутствуют.</i>\n";
    }
    
    push(keyboard, [ { text: "⬅️ Назад в меню", callback_data: "/help" } ]);
    
    let payload = {
        chat_id: int(chat_id),
        text: text,
        parse_mode: "HTML",
        reply_markup: { inline_keyboard: keyboard }
    };
    tg_request(token, "sendMessage", payload);
}

function handle_devices(token, chat_id) {
    let lease_file = "/tmp/dhcp.leases";
    let data = fs.readfile(lease_file);
    
    let firewall_c = uci_core.cursor();
    if (!firewall_c) {
        send_message(token, chat_id, "❌ Не удалось прочитать конфигурацию файрвола.");
        return;
    }
    firewall_c.load("firewall");
    let blocked_macs = {};
    firewall_c.foreach("firewall", "rule", function(r) {
        if (r.target == "REJECT" && r.src_mac) {
            blocked_macs[uc(as_string(r.src_mac))] = true;
        }
    });
    
    let text = "💻 <b>Активные устройства в сети:</b>\n\n";
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
            
            push(keyboard, [
                {
                    text: (is_blocked ? "🔓 Разблокировать " : "🚫 Заблокировать ") + hostname,
                    callback_data: "/toggle_mac " + mac
                }
            ]);
            count++;
        }
    }
    
    if (count == 0) {
        text += "<i>Устройства не найдены.</i>\n";
    }
    
    push(keyboard, [ { text: "⬅️ Назад в меню", callback_data: "/help" } ]);
    
    let payload = {
        chat_id: int(chat_id),
        text: text,
        parse_mode: "HTML",
        reply_markup: { inline_keyboard: keyboard }
    };
    tg_request(token, "sendMessage", payload);
}

function process_command(token, chat_id, text) {
    let cmd = trim(as_string(text));
    if (cmd == "/start" || cmd == "/help") {
        let help_text = "🤖 <b>Tachyon Bot</b> — Панель управления роутером\n\n" +
            "<b>Доступные команды:</b>\n" +
            "📊 /status — Статус системы и RAM/CPU\n" +
            "📡 /servers — Выбрать активный прокси-сервер\n" +
            "🛡️ /rules — Управление правилами обхода\n" +
            "💻 /devices — Подключенные устройства (DHCP)\n" +
            "🔄 /sub_update — Обновить прокси-подписки\n" +
            "⚡ /test — Быстрая проверка интернет-соединения\n" +
            "🚀 /speed — Замер скорости интернета (5MB)\n" +
            "📈 /traffic — Статистика трафика sing-box\n" +
            "🩺 /doctor — Запуск диагностики и ремонта\n" +
            "🔄 /restart — Перезапустить службы Tachyon\n" +
            "📋 /logs — Посмотреть последние логи\n" +
            "💾 /backup — Скачать резервную копию настроек\n" +
            "🌐 /bypass_add &lt;домен&gt; — Добавить домен в обход\n" +
            "🌐 /bypass_del &lt;домен&gt; — Удалить домен из обхода\n" +
            "🌐 /direct_add &lt;домен&gt; — Добавить домен в прямой доступ\n" +
            "🌐 /direct_del &lt;домен&gt; — Удалить домен из прямого доступа\n" +
            "🚫 /block_mac &lt;MAC&gt; — Заблокировать устройство по MAC\n" +
            "🔓 /unblock_mac &lt;MAC&gt; — Разблокировать устройство по MAC\n" +
            "📡 /ping &lt;хост&gt; — Пинг сетевого узла напрямую\n" +
            "🌐 /curl &lt;URL&gt; — Запрос к URL напрямую и через прокси\n" +
            "🔍 /nslookup &lt;домен&gt; — DNS-запрос через localhost роутера\n" +
            "💻 /sh &lt;команда&gt; — Выполнить консольную команду\n" +
            "❓ /help — Справка по командам\n";
        send_message_with_keyboard(token, chat_id, help_text, "HTML");
    }
    else if (cmd == "/status") {
        let sys = get_system_status();
        let status_text = "📊 <b>Статус Tachyon роутера</b>\n\n" +
            "Uptime: <code>" + sys.uptime + "</code>\n" +
            "CPU Load: <code>" + sys.cpu + "</code>\n" +
            "RAM: <code>" + sys.ram_avail + "MB / " + sys.ram_total + "MB</code> свободного\n" +
            "sing-box: <code>" + sys.singbox + "</code>";
        send_message_with_keyboard(token, chat_id, status_text, "HTML");
    }
    else if (cmd == "/servers") {
        handle_servers(token, chat_id);
    }
    else if (cmd == "/test") {
        handle_test(token, chat_id);
    }
    else if (cmd == "/speed") {
        run_speedtest(token, chat_id);
    }
    else if (cmd == "/traffic") {
        handle_traffic(token, chat_id);
    }
    else if (cmd == "/backup") {
        handle_backup(token, chat_id);
    }
    else if (cmd == "/doctor") {
        send_message(token, chat_id, "⏳ <b>Запуск диагностики и авто-исправления...</b>", "HTML");
        let doctor_res = command_capture("/usr/bin/tachyon doctor");
        let report = doctor_res.output || "Нет вывода диагностики.";
        send_message_with_keyboard(token, chat_id, "🩺 <b>Результаты Tachyon Doctor:</b>\n\n<pre>" + escape_html(report) + "</pre>", "HTML");
    }
    else if (cmd == "/restart") {
        send_message(token, chat_id, "🔄 <b>Перезапускаю службы Tachyon...</b>", "HTML");
        let restart_status = command_status("/usr/bin/tachyon restart");
        if (restart_status == 0) {
            send_message_with_keyboard(token, chat_id, "✅ <b>Перезапуск выполнен успешно!</b>", "HTML");
        } else {
            send_message_with_keyboard(token, chat_id, "❌ <b>Ошибка при перезапуске служб.</b>", "HTML");
        }
    }
    else if (cmd == "/logs") {
        let logs_res = command_capture("logread -e tachyon | tail -n 25");
        let logs = logs_res.output || "Логи отсутствуют.";
        send_message_with_keyboard(token, chat_id, "📋 <b>Последние логи Tachyon:</b>\n\n<pre>" + escape_html(logs) + "</pre>", "HTML");
    }
    else if (match(cmd, /^\/bypass_add /) != null) {
        let dom = trim(substr(cmd, 12));
        if (dom == "") {
            send_message_with_keyboard(token, chat_id, "❌ Укажите домен. Пример: `/bypass_add site.com`", "HTML");
            return;
        }
        let res = manage_domain_list("bypass", dom, false);
        if (res.success) {
            send_message_with_keyboard(token, chat_id, "✅ " + res.message, "HTML");
        } else {
            send_message_with_keyboard(token, chat_id, "❌ " + res.error, "HTML");
        }
    }
    else if (match(cmd, /^\/bypass_del /) != null) {
        let dom = trim(substr(cmd, 12));
        if (dom == "") {
            send_message_with_keyboard(token, chat_id, "❌ Укажите домен. Пример: `/bypass_del site.com`", "HTML");
            return;
        }
        let res = manage_domain_list("bypass", dom, true);
        if (res.success) {
            send_message_with_keyboard(token, chat_id, "✅ " + res.message, "HTML");
        } else {
            send_message_with_keyboard(token, chat_id, "❌ " + res.error, "HTML");
        }
    }
    else if (match(cmd, /^\/direct_add /) != null) {
        let dom = trim(substr(cmd, 12));
        if (dom == "") {
            send_message_with_keyboard(token, chat_id, "❌ Укажите домен. Пример: `/direct_add site.com`", "HTML");
            return;
        }
        let res = manage_domain_list("direct", dom, false);
        if (res.success) {
            send_message_with_keyboard(token, chat_id, "✅ " + res.message, "HTML");
        } else {
            send_message_with_keyboard(token, chat_id, "❌ " + res.error, "HTML");
        }
    }
    else if (match(cmd, /^\/direct_del /) != null) {
        let dom = trim(substr(cmd, 12));
        if (dom == "") {
            send_message_with_keyboard(token, chat_id, "❌ Укажите домен. Пример: `/direct_del site.com`", "HTML");
            return;
        }
        let res = manage_domain_list("direct", dom, true);
        if (res.success) {
            send_message_with_keyboard(token, chat_id, "✅ " + res.message, "HTML");
        } else {
            send_message_with_keyboard(token, chat_id, "❌ " + res.error, "HTML");
        }
    }
    else if (match(cmd, /^\/block_mac /) != null) {
        let mac = trim(substr(cmd, 11));
        if (match(mac, /^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$/) == null) {
            send_message_with_keyboard(token, chat_id, "❌ Неверный формат MAC-адреса. Пример: `00:1A:2B:3C:4D:5E`", "HTML");
            return;
        }
        let res = manage_mac_block(mac, false);
        if (res.success) {
            send_message_with_keyboard(token, chat_id, "✅ " + res.message, "HTML");
        } else {
            send_message_with_keyboard(token, chat_id, "❌ " + res.error, "HTML");
        }
    }
    else if (match(cmd, /^\/unblock_mac /) != null) {
        let mac = trim(substr(cmd, 13));
        if (match(mac, /^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$/) == null) {
            send_message_with_keyboard(token, chat_id, "❌ Неверный формат MAC-адреса. Пример: `00:1A:2B:3C:4D:5E`", "HTML");
            return;
        }
        let res = manage_mac_block(mac, true);
        if (res.success) {
            send_message_with_keyboard(token, chat_id, "✅ " + res.message, "HTML");
        } else {
            send_message_with_keyboard(token, chat_id, "❌ " + res.error, "HTML");
        }
    }
    else if (cmd == "/rules") {
        handle_rules(token, chat_id);
    }
    else if (match(cmd, /^\/toggle_rule /) != null) {
        let section = trim(substr(cmd, 13));
        let c = uci_core.cursor();
        if (c) {
            c.load("tachyon");
            let current = c.get("tachyon", section, "enabled") == "1" ? "0" : "1";
            c.set("tachyon", section, "enabled", current);
            c.commit("tachyon");
            command_status("/usr/bin/tachyon reload");
        }
        handle_rules(token, chat_id);
    }
    else if (cmd == "/devices") {
        handle_devices(token, chat_id);
    }
    else if (match(cmd, /^\/toggle_mac /) != null) {
        let mac = trim(substr(cmd, 12));
        let blocked = false;
        let c = uci_core.cursor();
        if (c) {
            c.load("firewall");
            c.foreach("firewall", "rule", function(r) {
                if (uc(as_string(r.src_mac)) == uc(mac) && r.target == "REJECT") {
                    blocked = true;
                    return false;
                }
            });
        }
        manage_mac_block(mac, blocked);
        handle_devices(token, chat_id);
    }
    else if (cmd == "/sub_update") {
        send_message(token, chat_id, "🔄 <b>Запуск обновления подписок...</b>", "HTML");
        let sub_res = command_capture("/usr/bin/tachyon subscription_update");
        let output = sub_res.output || "Обновление завершено.";
        send_message_with_keyboard(token, chat_id, "✅ <b>Результат обновления подписок:</b>\n\n<pre>" + escape_html(output) + "</pre>", "HTML");
    }
    else if (match(cmd, /^\/ping /) != null) {
        let host = trim(substr(cmd, 6));
        if (host == "" || match(host, /^[a-zA-Z0-9\.\-]+$/) == null) {
            send_message_with_keyboard(token, chat_id, "❌ Укажите корректный хост. Пример: `/ping google.com`", "HTML");
            return;
        }
        send_message(token, chat_id, "⏳ <b>Выполняю пинг " + escape_html(host) + "...</b>", "HTML");
        let ping_res = command_capture("ping -c 4 " + shell_quote(host));
        let output = ping_res.output || "Нет ответа.";
        send_message_with_keyboard(token, chat_id, "📡 <b>Результат пинга:</b>\n\n<pre>" + escape_html(output) + "</pre>", "HTML");
    }
    else if (match(cmd, /^\/curl /) != null) {
        let url = trim(substr(cmd, 6));
        if (url == "" || match(url, /^https?:\/\/[a-zA-Z0-9\.\-\/]+$/) == null) {
            send_message_with_keyboard(token, chat_id, "❌ Укажите корректный URL. Пример: `/curl https://google.com`", "HTML");
            return;
        }
        send_message(token, chat_id, "⏳ <b>Запрос к " + escape_html(url) + "...</b>", "HTML");
        
        let res_direct = command_capture("curl -I -s --connect-timeout 5 " + shell_quote(url));
        let out_direct = res_direct.output || "Нет ответа.";
        
        let res_proxy = command_capture("curl -I -s --connect-timeout 5 --proxy http://127.0.0.1:4534 " + shell_quote(url));
        let out_proxy = res_proxy.output || "Нет ответа.";
        
        let report = "🌐 <b>Результаты HTTP-запроса:</b>\n\n" +
            "<b>Напрямую:</b>\n<pre>" + escape_html(out_direct) + "</pre>\n" +
            "<b>Через прокси:</b>\n<pre>" + escape_html(out_proxy) + "</pre>";
            
        send_message_with_keyboard(token, chat_id, report, "HTML");
    }
    else if (match(cmd, /^\/nslookup /) != null) {
        let domain = trim(substr(cmd, 10));
        if (domain == "" || match(domain, /^[a-zA-Z0-9\.\-]+$/) == null) {
            send_message_with_keyboard(token, chat_id, "❌ Укажите корректный домен. Пример: `/nslookup google.com`", "HTML");
            return;
        }
        send_message(token, chat_id, "⏳ <b>Выполняю nslookup " + escape_html(domain) + " через localhost...</b>", "HTML");
        let lookup_res = command_capture("nslookup " + shell_quote(domain) + " 127.0.0.1");
        let output = lookup_res.output || "Нет ответа.";
        send_message_with_keyboard(token, chat_id, "🔍 <b>Результат DNS-запроса через localhost:</b>\n\n<pre>" + escape_html(output) + "</pre>", "HTML");
    }
    else if (match(cmd, /^\/switch /) != null) {
        let server_name = trim(substr(cmd, 8));
        clash_request("PUT", "proxies/main-out", { name: server_name });
        handle_servers(token, chat_id);
    }
    else if (match(cmd, /^\/sh /) != null) {
        let shell_cmd = substr(cmd, 4);
        send_message(token, chat_id, "⏳ <b>Выполнение команды:</b> <code>" + escape_html(shell_cmd) + "</code>", "HTML");
        let shell_res = command_capture(shell_cmd);
        let output = shell_res.output || "Команда выполнена без вывода.";
        if (length(output) > 3000) {
            output = substr(output, 0, 3000) + "\n...[вывод обрезан]...";
        }
        send_message_with_keyboard(token, chat_id, "💻 <b>Результат (код " + shell_res.status + "):</b>\n\n<pre>" + escape_html(output) + "</pre>", "HTML");
    }
    else {
        send_message_with_keyboard(token, chat_id, "⚠️ Неизвестная команда. Введите /help для списка команд.", "HTML");
    }
}
 
function process_updates(token, admin_ids) {
    let offset = int(trim(fs.readfile(OFFSET_FILE) || "0"));
    let res = tg_request(token, "getUpdates", { offset: offset, timeout: 20 });
    
    if (!res || !res.ok || !res.result || length(res.result) == 0) {
        return;
    }
    
    for (let upd in res.result) {
        let update_id = upd.update_id;
        if (update_id >= offset) {
            offset = update_id + 1;
            fs.writefile(OFFSET_FILE, as_string(offset));
        }
        
        let callback_query = upd.callback_query;
        if (callback_query) {
            let chat_id = callback_query.message ? callback_query.message.chat.id : callback_query.from.id;
            if (!is_admin(chat_id, admin_ids)) {
                send_message(token, chat_id, "❌ Доступ запрещен. Ваш Chat ID: `" + chat_id + "`", "Markdown");
                tg_request(token, "answerCallbackQuery", { callback_query_id: callback_query.id });
                continue;
            }
            
            process_command(token, chat_id, callback_query.data);
            tg_request(token, "answerCallbackQuery", { callback_query_id: callback_query.id });
            continue;
        }
        
        let msg = upd.message;
        if (!msg || !msg.text) continue;
        
        let chat_id = msg.chat.id;
        if (!is_admin(chat_id, admin_ids)) {
            send_message(token, chat_id, "❌ Доступ запрещен. Ваш Chat ID: `" + chat_id + "`", "Markdown");
            continue;
        }
        process_command(token, chat_id, msg.text);
    }
}

function check_new_dhcp_leases(token, admin_ids) {
    let lease_file = "/tmp/dhcp.leases";
    let data = fs.readfile(lease_file);
    if (!data) return;

    let known_macs_file = "/tmp/tachyon_known_macs.json";
    let known_macs = {};
    let known_data = fs.readfile(known_macs_file);
    if (known_data) {
        try {
            known_macs = json(known_data);
        } catch(e) {}
    }

    let is_first_run = (length(keys(known_macs)) == 0);
    let changed = false;

    for (let line in split(data, "\n")) {
        line = trim(line);
        if (line == "") continue;
        let fields = split(line, / /);
        if (length(fields) < 4) continue;

        let mac = uc(as_string(fields[1]));
        let ip = fields[2];
        let hostname = fields[3] == "*" ? "Неизвестно" : fields[3];

        if (!known_macs[mac]) {
            known_macs[mac] = { ip: ip, hostname: hostname, first_seen: time() };
            changed = true;

            if (!is_first_run) {
                let text = "📡 <b>Подключено новое устройство!</b>\n\n" +
                    "🖥️ Имя: <code>" + escape_html(hostname) + "</code>\n" +
                    "🌐 IP: <code>" + ip + "</code>\n" +
                    "🏷️ MAC: <code>" + mac + "</code>";

                let payload = {
                    text: text,
                    parse_mode: "HTML",
                    reply_markup: {
                        inline_keyboard: [
                            [
                                { text: "❌ Заблокировать", callback_data: "/block_mac " + mac }
                            ]
                        ]
                    }
                };

                let admins = split(admin_ids, /,/);
                for (let admin in admins) {
                    let chat_id = trim(admin);
                    if (chat_id != "") {
                        let p = { chat_id: int(chat_id) };
                        for (let k in keys(payload)) {
                            p[k] = payload[k];
                        }
                        tg_request(token, "sendMessage", p);
                    }
                }
            }
        }
    }

    if (changed) {
        fs.writefile(known_macs_file, sprintf("%J", known_macs));
    }
}

function worker() {
    let cfg = settings();
    if (cfg.enabled != "1" || !cfg.bot_token || !cfg.admin_ids) {
        return 0;
    }
    
    // Register commands on Telegram servers
    let commands = [
        { command: "status", description: "Статус системы и RAM/CPU" },
        { command: "servers", description: "Список серверов и задержка" },
        { command: "test", description: "Проверка интернет-соединения" },
        { command: "speed", description: "Замер скорости интернета" },
        { command: "traffic", description: "Статистика трафика sing-box" },
        { command: "doctor", description: "Диагностика и ремонт ошибок" },
        { command: "restart", description: "Перезапустить службы Tachyon" },
        { command: "logs", description: "Посмотреть последние логи" },
        { command: "help", description: "Справка по командам" }
    ];
    tg_request(cfg.bot_token, "setMyCommands", { commands: commands });
    
    let poll_interval = int(cfg.poll_interval || "5");
    if (poll_interval < 1) poll_interval = 1;
    
    let last_dhcp_check = 0;
    
    while (true) {
        cfg = settings();
        if (cfg.enabled != "1") {
            break;
        }
        
        process_updates(cfg.bot_token, cfg.admin_ids);
        
        let now = time();
        if (now - last_dhcp_check >= 30) {
            check_new_dhcp_leases(cfg.bot_token, cfg.admin_ids);
            last_dhcp_check = now;
        }
        
        sleep(poll_interval * 1000);
    }
    return 0;
}
 
function stop_runtime() {
    let pid = trim(fs.readfile(PID_FILE) || "");
    if (pid != "" && match(pid, /^[0-9]+$/) != null && command_success_from_args([ "kill", "-0", pid ])) {
        command_success_from_args([ "kill", pid ]);
    }
    fs.unlink(PID_FILE);
    return 0;
}
 
function start_runtime() {
    let cfg = settings();
    stop_runtime();
    
    if (cfg.enabled != "1" || !cfg.bot_token || !cfg.admin_ids) {
        return 0;
    }
    
    let command = command_from_args([ "ucode", "-L", LIB_DIR, LIB_DIR + "/service/telegram.uc", "worker" ]) +
        " </dev/null >/dev/null 2>&1 1000<&- & echo $! >" + shell_quote(PID_FILE);
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
    if (cfg.enabled != "1" || !cfg.bot_token || !cfg.admin_ids) {
        return 1;
    }
    
    let admins = split(cfg.admin_ids, /,/);
    for (let admin in admins) {
        let chat_id = trim(admin);
        if (chat_id != "") {
            send_message(cfg.bot_token, chat_id, message, "Markdown");
        }
    }
    return 0;
}
 
let mode = (ARGV[0] == "") ? ARGV[1] : ARGV[0];
if (!mode) mode = "";
 
if (mode == "start-runtime") {
    exit(start_runtime());
}
else if (mode == "stop-runtime") {
    exit(stop_runtime());
}
else if (mode == "worker") {
    exit(worker());
}
else if (mode == "status") {
    exit(get_status());
}
else if (mode == "send") {
    let msg = (ARGV[1] == "") ? ARGV[2] : ARGV[1];
    exit(send_api(msg));
}
else {
    warn("Usage: service/telegram.uc <start-runtime|stop-runtime|worker|status|send> ...\n");
    exit(1);
}
