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
    let payload_path = "/tmp/tg_payload_" + method + ".json";
    
    fs.writefile(payload_path, sprintf("%J", payload));
    
    let args = [ "curl", "-s", "-X", "POST", "-H", "Content-Type: application/json", "-d", "@" + payload_path ];
    let proxy = get_proxy_args();
    for (let p in proxy) {
        push(args, p);
    }
    push(args, url);
    
    let res = command_capture(command_from_args(args));
    fs.unlink(payload_path);
    
    if (res.status != 0 || res.output == "") {
        return null;
    }
    
    try {
        return json(res.output);
    }
    catch (e) {
        return null;
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
                    { text: "🚀 Скорость", callback_data: "/speed" },
                    { text: "📊 Трафик", callback_data: "/traffic" }
                ],
                [
                    { text: "⚡ Проверить", callback_data: "/test" },
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
 
function get_clash_proxies_data() {
    let args = [ "curl", "-s", "http://192.168.2.1:9090/proxies" ];
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
    let main_out = data.proxies["MAIN-out"];
    if (main_out && main_out.now) {
        active_server = main_out.now;
    }
    
    let text = "📡 *Список серверов и задержка:*\n\n";
    let count = 0;
    
    for (let name in keys(data.proxies)) {
        let proxy = data.proxies[name];
        let p_type = lc(as_string(proxy.type || ""));
        if (p_type == "vless" || p_type == "vmess" || p_type == "shadowsocks" || p_type == "trojan" || p_type == "socks" || p_type == "http") {
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
        }
    }
    
    if (count == 0) {
        text += "_Серверы не найдены._\n";
    } else {
        text += "\nℹ️ Активный сервер: *" + active_server + "*";
    }
    
    send_message_with_keyboard(token, chat_id, text, "Markdown");
}
 
function handle_traffic(token, chat_id) {
    let args = [ "curl", "-s", "http://192.168.2.1:9090/connections" ];
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
 
function process_command(token, chat_id, text) {
    let cmd = trim(as_string(text));
    if (cmd == "/start" || cmd == "/help") {
        let help_text = "🤖 *Tachyon Bot* — Панель управления роутером\n\n" +
            "Доступные команды:\n" +
            "⚡ /status — Статус системы и RAM/CPU\n" +
            "📡 /servers — Список серверов и задержка\n" +
            "⚡ /test — Проверка интернет-соединения\n" +
            "🚀 /speed — Замер скорости интернета\n" +
            "📊 /traffic — Статистика трафика sing-box\n" +
            "🩺 /doctor — Диагностика и ремонт ошибок\n" +
            "🔄 /restart — Перезапустить службы Tachyon\n" +
            "📋 /logs — Посмотреть последние логи\n";
        send_message_with_keyboard(token, chat_id, help_text, "Markdown");
    }
    else if (cmd == "/status") {
        let sys = get_system_status();
        let status_text = "📊 *Статус Tachyon роутера*\n\n" +
            "Uptime: `" + sys.uptime + "`\n" +
            "CPU Load: `" + sys.cpu + "`\n" +
            "RAM: `" + sys.ram_avail + "MB / " + sys.ram_total + "MB` свободного\n" +
            "sing-box: `" + sys.singbox + "`";
        send_message_with_keyboard(token, chat_id, status_text, "Markdown");
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
    else if (cmd == "/doctor") {
        send_message(token, chat_id, "⏳ *Запуск диагностики и авто-исправления...*");
        let doctor_res = command_capture("/usr/bin/tachyon doctor");
        let report = doctor_res.output || "Нет вывода диагностики.";
        send_message_with_keyboard(token, chat_id, "🩺 *Результаты Tachyon Doctor:*\n\n```\n" + report + "\n```", "Markdown");
    }
    else if (cmd == "/restart") {
        send_message(token, chat_id, "🔄 *Перезапускаю службы Tachyon...*");
        let restart_status = command_status("/usr/bin/tachyon restart");
        if (restart_status == 0) {
            send_message_with_keyboard(token, chat_id, "✅ *Перезапуск выполнен успешно!*");
        } else {
            send_message_with_keyboard(token, chat_id, "❌ *Ошибка при перезапуске служб.*");
        }
    }
    else if (cmd == "/logs") {
        let logs_res = command_capture("logread -e tachyon | tail -n 25");
        let logs = logs_res.output || "Логи отсутствуют.";
        send_message_with_keyboard(token, chat_id, "📋 *Последние логи Tachyon:*\n\n```\n" + logs + "\n```", "Markdown");
    }
    else {
        send_message_with_keyboard(token, chat_id, "⚠️ Неизвестная команда. Введите /help для списка команд.");
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
    
    while (true) {
        cfg = settings();
        if (cfg.enabled != "1") {
            break;
        }
        
        process_updates(cfg.bot_token, cfg.admin_ids);
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
