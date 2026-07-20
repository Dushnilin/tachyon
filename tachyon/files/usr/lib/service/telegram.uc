#!/usr/bin/env ucode
 
let fs = require("fs");
let uci_core = require("core.uci");
let common = require("core.common");
 
const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const PID_FILE = "/var/run/tachyon_telegram.pid";
const OFFSET_FILE = "/var/run/tachyon_telegram_offset";
const PAUSE_FILE = "/tmp/tachyon_paused_until";
const WATCHDOG_PID_FILE = "/var/run/tachyon_watchdog.pid";
const SMART_DETECT_COOLDOWN_FILE = "/tmp/tachyon_smart_detect_seen";
 
let as_string = common.as_string;
let shell_quote = common.shell_quote;
let object_or_empty = common.object_or_empty;

let command_status = common.command_status;
let command_success_from_args = common.command_success_from_args;
let command_from_args = common.command_from_args;

// ─── Language / Translation ───────────────────────────────────────────────────
let TG_LANG_RU = {
    status_title:      "📊 <b>Статус Tachyon роутера</b>",
    uptime:            "Аптайм",
    cpu_load:          "CPU Load",
    ram_free:          "RAM свободно",
    singbox_status:    "sing-box",
    active_server:     "🔵 Активный сервер",
    latency:           "Задержка",
    watchdog_status:   "Watchdog",
    paused_label:      "⏸️ На паузе, ещё",
    not_paused:        "",
    paused_notice:     "\n⏸️ <b>Прокси НА ПАУЗЕ</b> — ещё %s",
    pause_done:        "⏸️ Прокси приостановлен на <b>%s</b>. Возобновится через %s.",
    pause_invalid:     "❌ Укажите длительность: <code>/pause 30m</code> или <code>/pause 1h</code>",
    pause_max:         "❌ Максимальная пауза — 24 часа.",
    resume_done:       "▶️ Прокси возобновлён!",
    resume_not_paused: "ℹ️ Прокси не был на паузе.",
    wd_title:          "🐕 <b>Watchdog Tachyon</b>",
    wd_running:        "🟢 Запущен",
    wd_stopped:        "🔴 Остановлен",
    wd_btn_start:      "▶️ Запустить Watchdog",
    wd_btn_stop:       "⏹️ Остановить Watchdog",
    wd_started:        "✅ Watchdog запущен.",
    wd_stopped_msg:    "✅ Watchdog остановлен.",
    pick_section:      "Выберите секцию для <code>%s</code>:",
    no_sections_type:  "❌ Нет активных секций с действием '%s'.",
    pick_no_state:     "❌ Нет ожидающего домена. Введите /add <домен>.",
    domain_usage:      "❌ Укажите домен: <code>%s site.com</code>",
    smart_detect_title: "🔍 <b>Smart Detect</b> сработал!",
    smart_detect_msg:  "Домен <code>%s</code> недоступен напрямую, но работает через прокси.\nАвтоматически добавлен в секцию <b>%s</b>.",
    cmd_pause:  "Остановить прокси на время",
    cmd_resume: "Возобновить прокси",
    cmd_watchdog: "Управление Watchdog",
    cmd_add:    "Добавить домен в прокси-секцию",
    cmd_bypass: "Добавить домен в bypass"
};

let TG_LANG_EN = {
    status_title:      "📊 <b>Tachyon Router Status</b>",
    uptime:            "Uptime",
    cpu_load:          "CPU Load",
    ram_free:          "RAM free",
    singbox_status:    "sing-box",
    active_server:     "🔵 Active server",
    latency:           "Latency",
    watchdog_status:   "Watchdog",
    paused_label:      "⏸️ Paused, remaining",
    not_paused:        "",
    paused_notice:     "\n⏸️ <b>Proxy is PAUSED</b> — %s remaining",
    pause_done:        "⏸️ Proxy paused for <b>%s</b>. Will resume in %s.",
    pause_invalid:     "❌ Specify duration: <code>/pause 30m</code> or <code>/pause 1h</code>",
    pause_max:         "❌ Maximum pause is 24 hours.",
    resume_done:       "▶️ Proxy resumed!",
    resume_not_paused: "ℹ️ Proxy was not paused.",
    wd_title:          "🐕 <b>Tachyon Watchdog</b>",
    wd_running:        "🟢 Running",
    wd_stopped:        "🔴 Stopped",
    wd_btn_start:      "▶️ Start Watchdog",
    wd_btn_stop:       "⏹️ Stop Watchdog",
    wd_started:        "✅ Watchdog started.",
    wd_stopped_msg:    "✅ Watchdog stopped.",
    pick_section:      "Choose a section for <code>%s</code>:",
    no_sections_type:  "❌ No active sections with action '%s'.",
    pick_no_state:     "❌ No pending domain. Use /add <domain>.",
    domain_usage:      "❌ Specify domain: <code>%s site.com</code>",
    smart_detect_title: "🔍 <b>Smart Detect</b> triggered!",
    smart_detect_msg:  "Domain <code>%s</code> is unreachable directly but works via proxy.\nAutomatically added to section <b>%s</b>.",
    cmd_pause:  "Pause proxy for a while",
    cmd_resume: "Resume proxy",
    cmd_watchdog: "Watchdog control",
    cmd_add:    "Add domain to proxy section",
    cmd_bypass: "Add domain to bypass"
};

function get_lang() {
    let cfg = object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
    let lang = trim(as_string(cfg.language || ""));
    if (lang == "") {
        // Auto-detect from LuCI config
        let luci_c = uci_core.cursor();
        if (luci_c) {
            try {
                luci_c.load("luci");
                let luci_lang = as_string(luci_c.get("luci", "main", "lang") || "");
                if (index(luci_lang, "en") >= 0) lang = "en";
                else lang = "ru";
            } catch(e) { lang = "ru"; }
        } else { lang = "ru"; }
    }
    return (lang == "en") ? "en" : "ru";
}

function tl(lang, key) {
    let tr = (lang == "en") ? TG_LANG_EN : TG_LANG_RU;
    let val = tr[key];
    return (val != null) ? val : (key || "");
}

// ─── Pause / Resume helpers ───────────────────────────────────────────────────
function parse_pause_duration(str) {
    str = trim(as_string(str || ""));
    if (str == "") return 0;
    let m = match(str, /^([0-9]+)([mhMH]?)$/);
    if (!m) return 0;
    let n = int(m[1]);
    let unit = lc(m[2] || "m");
    if (unit == "h") return n * 3600;
    return n * 60;
}

function format_duration(seconds, lang) {
    seconds = int(seconds);
    if (seconds <= 0) return (lang == "en") ? "0 min" : "0 мин";
    let h = int(seconds / 3600);
    let m = int((seconds % 3600) / 60);
    if (lang == "en") {
        if (h > 0 && m > 0) return h + " h " + m + " min";
        if (h > 0) return h + " h";
        return m + " min";
    } else {
        if (h > 0 && m > 0) return h + " ч " + m + " мин";
        if (h > 0) return h + " ч";
        return m + " мин";
    }
}

function get_pause_remaining() {
    let val = trim(fs.readfile(PAUSE_FILE) || "");
    if (val == "") return 0;
    let until = int(val);
    let now = time();
    if (until <= now) return 0;
    return until - now;
}

function process_running_by_pidfile(pidfile) {
    let pid = trim(fs.readfile(pidfile) || "");
    return pid != "" && match(pid, /^[0-9]+$/) != null &&
           command_success_from_args(["kill", "-0", pid]);
}


function get_tg_state(chat_id) {
    let f = "/tmp/tg_state_" + chat_id + ".json";
    let data = fs.readfile(f);
    if (data) {
        try {
            return json(data);
        } catch(e) {}
    }
    return null;
}

function set_tg_state(chat_id, state_obj) {
    let f = "/tmp/tg_state_" + chat_id + ".json";
    if (state_obj == null) {
        fs.unlink(f);
    } else {
        fs.writefile(f, sprintf("%J", state_obj));
    }
}

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

function get_clash_url(endpoint) {
    let host = "127.0.0.1:9090"; // default fallback
    let config_data = fs.readfile("/etc/sing-box/config.json");
    if (config_data) {
        try {
            let sb_cfg = json(config_data);
            let ext = sb_cfg.experimental?.clash_api?.external_controller;
            if (ext) {
                let parts = split(ext, ":");
                let ip = (length(parts) > 1) ? parts[0] : "";
                let port = (length(parts) > 1) ? parts[length(parts) - 1] : "9090";
                if (ip == "0.0.0.0" || ip == "") {
                    host = "127.0.0.1:" + port;
                } else {
                    host = ext;
                }
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
                    { text: "🗂 Секции", callback_data: "/sections" },
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

function send_message_custom_keyboard(token, chat_id, text, parse_mode, keyboard) {
    let payload = {
        chat_id: int(chat_id),
        text: text,
        reply_markup: { inline_keyboard: keyboard }
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

function escape_html(text) {
    text = replace(as_string(text), /&/g, "&amp;");
    text = replace(text, /</g, "&lt;");
    text = replace(text, />/g, "&gt;");
    return text;
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
        } else if (index(line, "MemAvailable:") == 0) {
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

    // Active server + latency from Clash API
    status_obj.active_server = "";
    status_obj.latency = "";
    let pdata = get_clash_proxies_data();
    if (pdata && pdata.proxies) {
        let main_out = pdata.proxies["main-out"];
        if (main_out && main_out.now) {
            status_obj.active_server = main_out.now;
            let srv = pdata.proxies[main_out.now];
            if (srv && type(srv.history) == "array" && length(srv.history) > 0) {
                let last = srv.history[length(srv.history) - 1];
                if (last && last.delay) {
                    status_obj.latency = last.delay + " ms";
                }
            }
        }
    }

    // Watchdog status
    status_obj.watchdog_running = process_running_by_pidfile(WATCHDOG_PID_FILE);

    // Pause state
    status_obj.pause_remaining = get_pause_remaining();

    return status_obj;
}

function build_status_text(sys, lang) {
    let l = lang || "ru";
    let text = tl(l, "status_title") + "\n\n";
    text += tl(l, "uptime") + ": <code>" + sys.uptime + "</code>\n";
    text += tl(l, "cpu_load") + ": <code>" + sys.cpu + "</code>\n";
    text += tl(l, "ram_free") + ": <code>" + sys.ram_avail + "MB / " + sys.ram_total + "MB</code>\n";
    text += tl(l, "singbox_status") + ": <code>" + sys.singbox + "</code>\n";
    if (sys.active_server != "") {
        text += tl(l, "active_server") + ": <code>" + escape_html(sys.active_server) + "</code>";
        if (sys.latency != "") {
            text += " (" + tl(l, "latency") + ": <code>" + sys.latency + "</code>)";
        }
        text += "\n";
    }
    text += tl(l, "watchdog_status") + ": <code>" + (sys.watchdog_running ? "🟢 running" : "🔴 stopped") + "</code>";
    if (sys.pause_remaining > 0) {
        text += sprintf(tl(l, "paused_notice"), format_duration(sys.pause_remaining, l));
    }
    return text;
}
 
function format_bytes(b) {
    b = double(b || 0);
    if (b > 1073741824) return sprintf("%.2f GB", b / 1073741824);
    if (b > 1048576) return sprintf("%.2f MB", b / 1048576);
    if (b > 1024) return sprintf("%.2f KB", b / 1024);
    return sprintf("%d B", b);
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
 


function handle_sections(token, chat_id) {
    let c = uci_core.cursor();
    if (!c) return;
    c.load(CONFIG_NAME);
    
    let keyboard = [];
    let text = "🗂 *Управление секциями:*\n\nВыберите секцию для редактирования или создайте новую:";
    
    c.foreach(CONFIG_NAME, "section", function(s) {
        let act = s.action || "";
        if (act == "proxy" || act == "bypass" || act == "block" || act == "connection" || act == "awg" || act == "zapret" || act == "byedpi") {
            let label = s.label || s[".name"];
            let status = (s.enabled == "1") ? "✅" : "❌";
            push(keyboard, [{ text: status + " " + label + " (" + act + ")", callback_data: "/sec_view " + s[".name"] }]);
        }
    });

    c.foreach(CONFIG_NAME, "server", function(s) {
        let label = s.label || s[".name"];
        let status = (s.enabled == "1") ? "✅" : "❌";
        push(keyboard, [{ text: status + " " + label + " (inbound)", callback_data: "/sec_view " + s[".name"] }]);
    });
    
    push(keyboard, [{ text: "➕ Создать секцию", callback_data: "/sec_create" }]);
    push(keyboard, [{ text: "🔙 Отмена", callback_data: "/cancel" }]);
    
    send_message_custom_keyboard(token, chat_id, text, "Markdown", keyboard);
}

function handle_rule_view(token, chat_id, sec_name) {
    let c = uci_core.cursor();
    if (!c) return;
    c.load(CONFIG_NAME);

    let s = c.get_all(CONFIG_NAME, sec_name);
    if (!s) {
        send_message(token, chat_id, "❌ Секция не найдена: " + sec_name);
        return;
    }

    let act    = s.action || "";
    let status = (s.enabled == "1") ? "Включена ✅" : "Выключена ❌";

    // user_domains — домены, добавленные через бот/Smart Detect
    // domain      — статические правила из конфига
    let doms = s.user_domains || s.domain || [];
    if (type(doms) != "array") {
        doms = (trim(as_string(doms)) != "") ? split(trim(as_string(doms)), " ") : [];
    }

    let dom_list = "";
    let count = 0;
    for (let d in doms) {
        d = trim(as_string(d));
        if (d == "") continue;
        dom_list += "• <code>" + escape_html(d) + "</code>\n";
        count++;
        if (count >= 15) {
            dom_list += "<i>...и ещё " + (length(doms) - 15) + "</i>\n";
            break;
        }
    }
    if (count == 0) {
        dom_list = "<i>Пользовательские домены не добавлены</i>\n";
    }

    let label = escape_html(s.label || sec_name);
    let text = "⚙️ <b>Секция:</b> " + label + "\n" +
               "Тип: <code>" + escape_html(act) + "</code>\n" +
               "Статус: <b>" + status + "</b>\n\n" +
               "<b>Домены/IP (пользовательские):</b>\n" + dom_list;

    let keyboard = [
        [
            { text: "➕ Добавить", callback_data: "/rule_add " + sec_name },
            { text: "➖ Удалить",  callback_data: "/rule_del " + sec_name }
        ],
        [
            { text: "⚡ Вкл / Выкл", callback_data: "/rule_toggle " + sec_name }
        ],
        [
            { text: "🔙 Назад к списку", callback_data: "/rules" }
        ]
    ];

    let res = send_message_custom_keyboard(token, chat_id, text, "HTML", keyboard);
    if (!res || !res.ok) {
        let desc = (res && res.description) ? " (" + res.description + ")" : "";
        send_message(token, chat_id, "❌ Ошибка отображения секции" + desc + ". Секция: " + sec_name + ", действие: " + act);
    }
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

function manage_domain_list_by_section(sec_name, domain, do_delete) {
    let c = uci_core.cursor();
    if (!c) return { success: false, error: "Не удалось инициализировать UCI" };
    c.load(CONFIG_NAME);

    let s = c.get_all(CONFIG_NAME, sec_name);
    if (!s) {
        return { success: false, error: "Секция '" + sec_name + "' не найдена." };
    }

    let option_path = CONFIG_NAME + "." + sec_name + ".domain";

    if (do_delete) {
        let deleted = uci_core.del_list(option_path, domain);
        if (deleted) {
            uci_core.commit(CONFIG_NAME);
            command_status("/usr/bin/tachyon reload");
            return { success: true, message: "Запись <code>" + domain + "</code> удалена." };
        } else {
            return { success: false, error: "Запись <code>" + domain + "</code> не найдена." };
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
            return { success: false, error: "Запись <code>" + domain + "</code> уже есть в секции." };
        }

        let added = uci_core.add_list(option_path, domain);
        if (added) {
            uci_core.commit(CONFIG_NAME);
            command_status("/usr/bin/tachyon reload");
            return { success: true, message: "Запись <code>" + domain + "</code> добавлена." };
        }
        return { success: false, error: "Не удалось добавить запись." };
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

// ─── Pause / Resume handlers ──────────────────────────────────────────────────
function handle_pause(token, chat_id, duration_str, lang) {
    let seconds = parse_pause_duration(duration_str);
    if (seconds <= 0) {
        send_message_with_keyboard(token, chat_id, tl(lang, "pause_invalid"), "HTML");
        return;
    }
    if (seconds > 86400) {
        send_message_with_keyboard(token, chat_id, tl(lang, "pause_max"), "HTML");
        return;
    }
    fs.writefile(PAUSE_FILE, as_string(time() + seconds));
    command_status("/usr/bin/tachyon stop");
    // Schedule auto-resume in background
    let resume_cmd = "sleep " + as_string(seconds) +
        " && rm -f " + shell_quote(PAUSE_FILE) +
        " && /usr/bin/tachyon start";
    command_status("(" + resume_cmd + ") < /dev/null > /dev/null 2>&1 &");
    let dur_str = format_duration(seconds, lang);
    let text = sprintf(tl(lang, "pause_done"), dur_str, dur_str);
    send_message_with_keyboard(token, chat_id, text, "HTML");
}

function handle_resume(token, chat_id, lang) {
    let remaining = get_pause_remaining();
    if (remaining <= 0) {
        send_message_with_keyboard(token, chat_id, tl(lang, "resume_not_paused"), "HTML");
        return;
    }
    fs.unlink(PAUSE_FILE);
    command_status("/usr/bin/tachyon start");
    send_message_with_keyboard(token, chat_id, tl(lang, "resume_done"), "HTML");
}

// ─── Watchdog control ─────────────────────────────────────────────────────────
function handle_watchdog(token, chat_id, lang) {
    let running = process_running_by_pidfile(WATCHDOG_PID_FILE);
    let status_str = running ? tl(lang, "wd_running") : tl(lang, "wd_stopped");
    let text = tl(lang, "wd_title") + "\n\n" +
        "Watchdog: <code>" + status_str + "</code>";
    let keyboard = [[
        running
            ? { text: tl(lang, "wd_btn_stop"), callback_data: "/wd_stop" }
            : { text: tl(lang, "wd_btn_start"), callback_data: "/wd_start" }
    ], [
        { text: "⬅️ " + (lang == "en" ? "Back" : "Назад"), callback_data: "/help" }
    ]];
    let payload = {
        chat_id: int(chat_id),
        text: text,
        parse_mode: "HTML",
        reply_markup: { inline_keyboard: keyboard }
    };
    tg_request(token, "sendMessage", payload);
}

// ─── Domain add with section picker ──────────────────────────────────────────
function handle_add_domain_picker(token, chat_id, domain, action_type, lang) {
    domain = trim(as_string(domain || ""));
    if (domain == "") {
        let usage = sprintf(tl(lang, "domain_usage"), "/" + action_type);
        send_message_with_keyboard(token, chat_id, usage, "HTML");
        return;
    }
    let c = uci_core.cursor();
    if (!c) {
        send_message(token, chat_id, "❌ UCI error");
        return;
    }
    c.load(CONFIG_NAME);
    let keyboard = [];
    let section_actions = (action_type == "bypass") ? ["bypass"] : ["proxy", "connection", "outbound", "vpn"];
    c.foreach(CONFIG_NAME, "section", function(s) {
        if (s.enabled != "1") return;
        let act = as_string(s.action || "");
        let ok = false;
        for (let sa in section_actions) {
            if (sa == act) { ok = true; break; }
        }
        if (!ok) return;
        let label = as_string(s.label || s[".name"]);
        push(keyboard, [{ text: label + " (" + act + ")", callback_data: "/do_pick " + s[".name"] }]);
    });
    if (length(keyboard) == 0) {
        let msg = sprintf(tl(lang, "no_sections_type"), action_type);
        send_message_with_keyboard(token, chat_id, msg, "HTML");
        return;
    }
    if (length(keyboard) == 1) {
        // Only one section — add directly
        let sec = split(keyboard[0][0].callback_data, " ")[1];
        let res = manage_domain_list_by_section(sec, domain, false);
        send_message_with_keyboard(token, chat_id, (res.success ? "✅ " : "❌ ") + (res.message || res.error), "HTML");
        return;
    }
    // Store domain in state, show section picker
    set_tg_state(chat_id, { action: "pick_section_add", domain: domain, action_type: action_type });
    push(keyboard, [{ text: "🔙 " + (lang == "en" ? "Cancel" : "Отмена"), callback_data: "/cancel" }]);
    let prompt = sprintf(tl(lang, "pick_section"), escape_html(domain));
    send_message_custom_keyboard(token, chat_id, prompt, "HTML", keyboard);
}

function process_command(token, chat_id, text) {
    let cmd = trim(as_string(text));
    let lang = get_lang();

    let state = get_tg_state(chat_id);
    if (state && cmd != "/cancel" && cmd != "/rules" && cmd != "/start") {
        if (state.action == "wait_add") {
            let items = split(cmd, "\n");
            let msg = "";
            for (let it in items) {
                let i = trim(it);
                if (i != "") {
                    let r = manage_domain_list_by_section(state.section, i, false);
                    msg += (r.success ? "✅ " : "❌ ") + (r.message || r.error) + "\n";
                }
            }
            send_message(token, chat_id, msg, "HTML");
            set_tg_state(chat_id, null);
            handle_sec_view(token, chat_id, state.section);
            return;
        } else if (state.action == "wait_del") {
            let r = manage_domain_list_by_section(state.section, cmd, true);
            send_message(token, chat_id, (r.success ? "✅ " : "❌ ") + (r.message || r.error), "HTML");
            set_tg_state(chat_id, null);
            handle_sec_view(token, chat_id, state.section);
            return;
        } else if (state.action == "wait_sec_name") {
            let name = trim(cmd);
            if (name == "") {
                send_message(token, chat_id, "❌ Имя не может быть пустым.");
                return;
            }
            set_tg_state(chat_id, null);
            do_sec_create(token, chat_id, name, state.type);
            return;
        } else if (state.action == "wait_sec_url") {
            let url = trim(cmd);
            if (url == "") return;
            let c = uci_core.cursor();
            c.load(CONFIG_NAME);
            let sub = null;
            c.foreach(CONFIG_NAME, "subscription_url", function(u) {
                if (u.section == state.section) sub = u;
            });
            if (sub) {
                c.set(CONFIG_NAME, sub[".name"], "url", url);
                c.commit(CONFIG_NAME);
                command_status("/usr/bin/tachyon reload");
            }
            set_tg_state(chat_id, null);
            handle_sec_view(token, chat_id, state.section, "section");
            return;
        }
    }

    if (cmd == "/cancel") {
        set_tg_state(chat_id, null);
        send_message(token, chat_id, "ℹ️ " + (lang == "en" ? "Action cancelled." : "Действие отменено."));
        return;
    }

    if (cmd == "/start" || cmd == "/help") {
        let en = (lang == "en");
        let help_text = "🤖 <b>Tachyon Bot</b> — " + (en ? "Router Control Panel" : "Панель управления роутером") + "\n\n" +
            "<b>" + (en ? "Commands:" : "Доступные команды:") + "</b>\n" +
            "📊 /status — " + (en ? "System status, server, latency" : "Статус системы, сервер, задержка") + "\n" +
            "🗂 /sections — " + (en ? "Manage routing sections" : "Управление секциями") + "\n" +
            "📡 /servers — " + (en ? "Select active proxy server" : "Выбрать активный прокси-сервер") + "\n" +
            "💻 /devices — " + (en ? "Connected devices (DHCP)" : "Подключенные устройства (DHCP)") + "\n" +
            "⏸️ /pause &lt;30m|1h&gt; — " + (en ? "Pause proxy for a period" : "Приостановить прокси на время") + "\n" +
            "▶️ /resume — " + (en ? "Resume proxy" : "Возобновить прокси") + "\n" +
            "🐕 /watchdog — " + (en ? "Watchdog status and control" : "Watchdog: статус и управление") + "\n" +
            "➕ /add &lt;domain&gt; — " + (en ? "Add domain to proxy section" : "Добавить домен в прокси-секцию") + "\n" +
            "🛡️ /bypass &lt;domain&gt; — " + (en ? "Add domain to bypass section" : "Добавить домен в bypass") + "\n" +
            "🔄 /sub_update — " + (en ? "Update proxy subscriptions" : "Обновить прокси-подписки") + "\n" +
            "⚡ /test — " + (en ? "Quick connection check" : "Быстрая проверка соединения") + "\n" +
            "🚀 /speed — " + (en ? "Speed test (5MB)" : "Замер скорости интернета (5MB)") + "\n" +
            "📈 /traffic — " + (en ? "sing-box traffic stats" : "Статистика трафика sing-box") + "\n" +
            "🩺 /doctor — " + (en ? "Diagnostics and repair" : "Запуск диагностики и ремонта") + "\n" +
            "🔄 /restart — " + (en ? "Restart Tachyon services" : "Перезапустить службы Tachyon") + "\n" +
            "📋 /logs — " + (en ? "View recent logs" : "Посмотреть последние логи") + "\n" +
            "💾 /backup — " + (en ? "Download settings backup" : "Скачать резервную копию настроек") + "\n" +
            "🌐 /bypass_add &lt;domain&gt; — " + (en ? "Add to bypass" : "Добавить домен в обход") + "\n" +
            "🌐 /direct_add &lt;domain&gt; — " + (en ? "Add to direct" : "Добавить домен в прямой доступ") + "\n" +
            "🚫 /block_mac &lt;MAC&gt; — " + (en ? "Block device by MAC" : "Заблокировать устройство по MAC") + "\n" +
            "📡 /ping &lt;host&gt; — " + (en ? "Ping host" : "Пинг сетевого узла") + "\n" +
            "💻 /sh &lt;cmd&gt; — " + (en ? "Execute shell command" : "Выполнить консольную команду") + "\n" +
            "❓ /help — " + (en ? "This help" : "Справка по командам") + "\n";
        send_message_with_keyboard(token, chat_id, help_text, "HTML");
    }
    else if (cmd == "/sections") {
        handle_sections(token, chat_id);
    }
    else if (cmd == "/status") {
        let sys = get_system_status();
        send_message_with_keyboard(token, chat_id, build_status_text(sys, lang), "HTML");
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
    else if (cmd == "/sections") {
        handle_sections(token, chat_id);
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
    else if (match(cmd, /^\/pause( |$)/) != null) {
        let dur = trim(substr(cmd, 7));
        handle_pause(token, chat_id, dur, lang);
    }
    else if (cmd == "/resume") {
        handle_resume(token, chat_id, lang);
    }
    else if (cmd == "/watchdog") {
        handle_watchdog(token, chat_id, lang);
    }
    else if (match(cmd, /^\/add( |$)/) != null) {
        let dom = trim(substr(cmd, 5));
        handle_add_domain_picker(token, chat_id, dom, "proxy", lang);
    }
    else if (match(cmd, /^\/bypass( |$)/) != null) {
        let dom = trim(substr(cmd, 8));
        handle_add_domain_picker(token, chat_id, dom, "bypass", lang);
    }
    else {
        let unknown = (lang == "en")
            ? "⚠️ Unknown command. Type /help for the list."
            : "⚠️ Неизвестная команда. Введите /help для списка команд.";
        send_message_with_keyboard(token, chat_id, unknown, "HTML");
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
            
            let data = callback_query.data;
            let lang = get_lang();
            if (match(data, /^\/sec_create/) != null) {
                handle_sec_create(token, chat_id);
            }
            else if (match(data, /^\/sec_new /) != null) {
                handle_sec_new(token, chat_id, trim(substr(data, 9)));
            }
            else if (match(data, /^\/sec_view /) != null) {
                handle_sec_view(token, chat_id, trim(substr(data, 10)), null);
            }
            else if (match(data, /^\/sec_com /) != null) {
                handle_sec_communities(token, chat_id, trim(substr(data, 9)));
            }
            else if (match(data, /^\/sec_ctog /) != null) {
                let parts = split(trim(substr(data, 10)), " ");
                let sec_id = parts[0];
                let com = parts[1];
                let c = uci_core.cursor();
                c.load(CONFIG_NAME);
                let current = c.get(CONFIG_NAME, sec_id, "community_lists") || [];
                if (type(current) != "array") current = split(current, " ");
                let n_list = [];
                let found = false;
                for (let i in current) {
                    if (trim(current[i]) == com) found = true;
                    else if (trim(current[i]) != "") push(n_list, trim(current[i]));
                }
                if (!found) push(n_list, com);
                c.set(CONFIG_NAME, sec_id, "community_lists", n_list);
                c.commit(CONFIG_NAME);
                handle_sec_communities(token, chat_id, sec_id);
            }
            else if (match(data, /^\/sec_save /) != null) {
                let sec_id = trim(substr(data, 10));
                command_status("/usr/bin/tachyon reload");
                handle_sec_view(token, chat_id, sec_id, null);
            }
            else if (match(data, /^\/sec_toggle /) != null) {
                let sec = trim(substr(data, 12));
                let c = uci_core.cursor();
                c.load(CONFIG_NAME);
                let s = c.get_all(CONFIG_NAME, sec);
                if (s) {
                    let new_state = (s.enabled == "1") ? "0" : "1";
                    c.set(CONFIG_NAME, sec, "enabled", new_state);
                    c.commit(CONFIG_NAME);
                    command_status("/usr/bin/tachyon reload");
                }
                handle_sec_view(token, chat_id, sec, null);
            }
            else if (match(data, /^\/sec_del /) != null) {
                let sec = trim(substr(data, 9));
                let c = uci_core.cursor();
                c.load(CONFIG_NAME);
                c.del(CONFIG_NAME, sec);
                c.commit(CONFIG_NAME);
                command_status("/usr/bin/tachyon reload");
                handle_sections(token, chat_id);
            }
            else if (match(data, /^\/sec_url /) != null) {
                let sec = trim(substr(data, 9));
                set_tg_state(chat_id, { action: "wait_sec_url", section: sec });
                let text = "🔗 Отправьте новый URL подписки текстом:\n\n_Или нажмите /cancel_";
                send_message_custom_keyboard(token, chat_id, text, "Markdown", [[{text:"🔙 Отмена", callback_data:"/cancel"}]]);
            }
            else if (data == "/cancel") {
                set_tg_state(chat_id, null);
                send_message(token, chat_id, "ℹ️ " + (lang == "en" ? "Action cancelled." : "Действие отменено."));
            }
            else if (data == "/sections") {
                handle_sections(token, chat_id);
            }
            else if (data == "/wd_start") {
                command_status("/usr/bin/tachyon watchdog_start");
                let msg_text = tl(lang, "wd_started");
                send_message(token, chat_id, msg_text, "HTML");
                handle_watchdog(token, chat_id, lang);
            }
            else if (data == "/wd_stop") {
                command_status("/usr/bin/tachyon watchdog_stop");
                let msg_text = tl(lang, "wd_stopped_msg");
                send_message(token, chat_id, msg_text, "HTML");
                handle_watchdog(token, chat_id, lang);
            }
            else if (match(data, /^\/do_pick /) != null) {
                let sec_name = trim(substr(data, 9));
                let st = get_tg_state(chat_id);
                if (st && st.action == "pick_section_add" && st.domain) {
                    set_tg_state(chat_id, null);
                    let res = manage_domain_list_by_section(sec_name, st.domain, false);
                    send_message_with_keyboard(token, chat_id, (res.success ? "✅ " : "❌ ") + (res.message || res.error), "HTML");
                } else {
                    send_message(token, chat_id, tl(lang, "pick_no_state"), "HTML");
                }
            }
            else if (match(data, /^\/toggle_mac /) != null) {
                let mac = trim(substr(data, 12));
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
            else {
                process_command(token, chat_id, data);
            }
            
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

    // Register commands on Telegram servers (language-aware)
    let lang = get_lang();
    let commands = [
        { command: "status",    description: (lang == "en") ? "System status, server, latency"  : "Статус системы, сервер, задержка" },
        { command: "servers",   description: (lang == "en") ? "Proxy servers and latency"        : "Список серверов и задержка" },
        { command: "pause",     description: (lang == "en") ? "Pause proxy (e.g. /pause 30m)"    : "Пауза прокси (напр. /pause 30m)" },
        { command: "resume",    description: (lang == "en") ? "Resume proxy"                     : "Возобновить прокси" },
        { command: "watchdog",  description: (lang == "en") ? "Watchdog status and control"      : "Watchdog: статус и управление" },
        { command: "add",       description: (lang == "en") ? "Add domain to proxy section"      : "Добавить домен в прокси-секцию" },
        { command: "bypass",    description: (lang == "en") ? "Add domain to bypass section"     : "Добавить домен в bypass" },
        { command: "test",      description: (lang == "en") ? "Quick connection check"           : "Проверка интернет-соединения" },
        { command: "speed",     description: (lang == "en") ? "Speed test (5MB)"                : "Замер скорости интернета (5MB)" },
        { command: "traffic",   description: (lang == "en") ? "sing-box traffic stats"           : "Статистика трафика sing-box" },
        { command: "doctor",    description: (lang == "en") ? "Diagnostics and repair"           : "Диагностика и ремонт ошибок" },
        { command: "restart",   description: (lang == "en") ? "Restart Tachyon services"         : "Перезапустить службы Tachyon" },
        { command: "devices",   description: (lang == "en") ? "Connected devices (DHCP)"         : "Подключённые устройства (DHCP)" },
        { command: "rules",     description: (lang == "en") ? "Manage routing rules"             : "Управление правилами" },
        { command: "logs",      description: (lang == "en") ? "Recent logs"                     : "Последние логи" },
        { command: "backup",    description: (lang == "en") ? "Download settings backup"         : "Резервная копия настроек" },
        { command: "help",      description: (lang == "en") ? "Help"                            : "Справка по командам" }
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


function get_random_string(length) {
    let chars = "abcdefghijklmnopqrstuvwxyz0123456789";
    let res = "";
    for (let i = 0; i < length; i++) {
        res += substr(chars, int(rand() * length(chars)), 1);
    }
    return res;
}

function handle_sec_create(token, chat_id) {
    let text = "➕ *Создание секции*\n\nВыберите тип секции:";
    let keyboard = [
        [{ text: "🔗 Подписка (Subscription)", callback_data: "/sec_new sub" }],
        [{ text: "📝 Пользовательский JSON Outbound", callback_data: "/sec_new json" }],
        [{ text: "💻 Входящий сервер (Inbound)", callback_data: "/sec_new srv" }],
        [{ text: "🔙 Отмена", callback_data: "/sections" }]
    ];
    send_message_custom_keyboard(token, chat_id, text, "Markdown", keyboard);
}

function handle_sec_new(token, chat_id, type_arg) {
    set_tg_state(chat_id, { action: "wait_sec_name", type: type_arg });
    let text = "✏️ Отправьте название (label) для новой секции текстом:\n\n_Или нажмите /cancel_";
    send_message_custom_keyboard(token, chat_id, text, "Markdown", [[{text:"🔙 Отмена", callback_data:"/cancel"}]]);
}

function do_sec_create(token, chat_id, name, type_arg) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let sec_id = "";
    if (type_arg == "sub") sec_id = "sub_" + get_random_string(6);
    else if (type_arg == "json") sec_id = "json_" + get_random_string(6);
    else if (type_arg == "srv") sec_id = "srv_" + get_random_string(6);
    else sec_id = "sec_" + get_random_string(6);
    
    if (type_arg == "srv") {
        c.add(CONFIG_NAME, "server", sec_id);
    } else {
        c.add(CONFIG_NAME, "section", sec_id);
    }
    c.set(CONFIG_NAME, sec_id, "label", name);
    c.set(CONFIG_NAME, sec_id, "enabled", "0");
    if (type_arg != "srv") {
        c.set(CONFIG_NAME, sec_id, "action", "connection");
    }
    
    if (type_arg == "sub") {
        c.add(CONFIG_NAME, "subscription_url", sec_id);
        c.set(CONFIG_NAME, sec_id, "section", sec_id);
        c.set(CONFIG_NAME, sec_id, "url", "https://...");
    } else if (type_arg == "json") {
        c.set(CONFIG_NAME, sec_id, "outbound_jsons", "{\"type\":\"socks\",\"tag\":\"Local SOCKS\",\"server\":\"127.0.0.1\",\"server_port\":1080,\"version\":\"5\"}");
    } else if (type_arg == "srv") {
        c.set(CONFIG_NAME, sec_id, "protocol", "vless");
    }
    
    c.commit(CONFIG_NAME);
    send_message(token, chat_id, "✅ Секция `" + sec_id + "` создана. Пожалуйста, настройте её ниже.", "Markdown");
    handle_sec_view(token, chat_id, sec_id, type_arg == "srv" ? "server" : "section");
}

function handle_sec_view(token, chat_id, sec_id, config_type) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    if (!config_type) {
        config_type = "section";
        if (c.get_all(CONFIG_NAME, sec_id) == null) {
            c.foreach(CONFIG_NAME, "server", function(s) {
                if (s[".name"] == sec_id) config_type = "server";
            });
        }
    }
    let s = c.get_all(CONFIG_NAME, sec_id);
    if (!s) {
        send_message(token, chat_id, "❌ Секция не найдена: " + sec_id);
        return;
    }

    let status = (s.enabled == "1") ? "Включена ✅" : "Выключена ❌";
    let label = escape_html(s.label || sec_id);
    let act = escape_html(s.action || s.protocol || "none");
    
    let text = "⚙️ <b>Секция:</b> " + label + "\n" +
               "Тип: <code>" + act + "</code>\n" +
               "Статус: <b>" + status + "</b>\n\n";

    let keyboard = [];
    push(keyboard, [{ text: (s.enabled == "1" ? "🔴 Выключить" : "🟢 Включить"), callback_data: "/sec_toggle " + sec_id }]);
    push(keyboard, [{ text: "✏️ Переименовать", callback_data: "/sec_rename " + sec_id }]);
    
    if (config_type == "section") {
        push(keyboard, [{ text: "⚙️ Изменить Action", callback_data: "/sec_action " + sec_id }]);
        push(keyboard, [{ text: "📋 Списки маршрутизации", callback_data: "/sec_com " + sec_id }]);
    }
    
    let sub = null;
    c.foreach(CONFIG_NAME, "subscription_url", function(u) {
        if (u.section == sec_id) sub = u;
    });
    
    if (sub) {
        let url = escape_html(sub.url || "отсутствует");
        text += "URL Подписки:\n<code>" + url + "</code>\n";
        push(keyboard, [{ text: "🔗 Изменить URL", callback_data: "/sec_url " + sec_id }]);
    }
    
    if (config_type == "server") {
        text += "Входящий протокол: <code>" + act + "</code>\n";
    }

    push(keyboard, [{ text: "🗑 Удалить", callback_data: "/sec_del " + sec_id }]);
    push(keyboard, [{ text: "🔙 Назад к списку", callback_data: "/sections" }]);

    send_message_custom_keyboard(token, chat_id, text, "HTML", keyboard);
}

function handle_sec_communities(token, chat_id, sec_id) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let s = c.get_all(CONFIG_NAME, sec_id);
    if (!s) return;
    
    let current = s.community_lists || [];
    if (type(current) != "array") current = split(current, " ");
    let cur_map = {};
    for (let com in current) {
        if (trim(com) != "") cur_map[trim(com)] = true;
    }
    
    let all_communities = "russia_inside russia_outside ukraine_inside geoblock block porn news anime youtube hdrezka tiktok google_ai google_play hodca discord meta twitter cloudflare cloudfront digitalocean hetzner ovh telegram roblox ads_hagezi_pro supercell github";
    let com_list = split(all_communities, " ");
    
    let text = "📋 <b>Списки маршрутизации для:</b> " + escape_html(s.label || sec_id) + "\n\nВыберите нужные списки:";
    let keyboard = [];
    
    let row = [];
    for (let com in com_list) {
        let is_sel = cur_map[com] === true;
        let btn_text = (is_sel ? "✅ " : "⬜️ ") + com;
        push(row, { text: btn_text, callback_data: "/sec_ctog " + sec_id + " " + com });
        if (length(row) == 2) {
            push(keyboard, row);
            row = [];
        }
    }
    if (length(row) > 0) push(keyboard, row);
    
    push(keyboard, [{ text: "💾 Сохранить и применить", callback_data: "/sec_save " + sec_id }]);
    push(keyboard, [{ text: "🔙 Назад к секции", callback_data: "/sec_view " + sec_id }]);
    
    send_message_custom_keyboard(token, chat_id, text, "HTML", keyboard);
}

