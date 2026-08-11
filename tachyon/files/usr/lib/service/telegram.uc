#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");
let common = require("core.common");
let api = require("service.api");
let dns_presets = require("singbox.dns_presets"); // Our new API module

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const PID_FILE = "/var/run/tachyon_telegram.pid";
const OFFSET_FILE = "/var/run/tachyon_telegram_offset";

let as_string = common.as_string;
let option = common.option;
let shell_quote = common.shell_quote;
let object_or_empty = common.object_or_empty;
let command_status = common.command_status;
let command_success_from_args = common.command_success_from_args;
let command_from_args = common.command_from_args;
let command_capture = common.command_capture;
let command_output_from_args = common.command_output_from_args;

// ─── Callback Data Helpers ────────────────────────────────────────────────────

// Telegram limits callback_data to 64 *bytes*. ucode strings are byte based, so
// length() already reports bytes. Payloads longer than that used to be truncated,
// which silently broke deletion of long entries (and could split a UTF-8 sequence
// mid-character, making Telegram reject the whole keyboard). Instead we now store
// the full payload in a small on-disk map and send a short opaque token.
const CB_MAP_FILE = "/tmp/tg_cb_map.json";
const CB_MAP_MAX = 300;

function cb_map_load() {
    let data = fs.readfile(CB_MAP_FILE);
    if (data) {
        try {
            let obj = json(data);
            if (type(obj) == "object") return obj;
        }
        catch (e) {
            // A truncated map is recoverable: the tokens in it are short-lived
            // and the next store rewrites the file. Starting from empty costs
            // the user a "кнопка устарела" on old keyboards, which is what the
            // caller reports anyway when a token is missing.
            command_success_from_args([ "logger", "-t", "tachyon-telegram",
                "[warn] callback map is unparseable, starting from empty: " + as_string(e) ]);
        }
    }
    return {};
}

function cb_map_store(token, value) {
    let map = cb_map_load();
    let ks = keys(map);
    if (length(ks) >= CB_MAP_MAX) {
        // Drop the oldest half so long-lived keyboards keep working for a while
        let pruned = {};
        for (let i = int(length(ks) / 2); i < length(ks); i++)
            pruned[ks[i]] = map[ks[i]];
        map = pruned;
    }
    map[token] = value;
    // The token has already been embedded in the keyboard by the time this runs,
    // so a failed write hands the user a button that will answer "кнопка
    // устарела" the moment they press it. Silently swallowing that made the
    // keyboard look intermittently broken with nothing in the log.
    let stored = false;
    try {
        stored = fs.writefile(CB_MAP_FILE, sprintf("%J", map)) != null;
    }
    catch (e) {
        command_success_from_args([ "logger", "-t", "tachyon-telegram",
            "[err] Failed to store callback map, buttons in this keyboard will not work: " + as_string(e) ]);
        return;
    }
    if (!stored)
        command_success_from_args([ "logger", "-t", "tachyon-telegram",
            "[err] Failed to store callback map, buttons in this keyboard will not work" ]);
}

function cb_map_get(token) {
    let map = cb_map_load();
    let val = map[as_string(token)];
    return (type(val) == "string") ? val : null;
}

function cb_data(args) {
    let s = join(" ", args);
    if (length(s) <= 64) return s;
    let h = 0;
    for (let i = 0; i < length(s); i++)
        h = ((h << 5) - h + ord(s, i)) | 0;
    // Mix the length into the token to make accidental collisions far less likely
    let token = sprintf("%08x%02x", h & 0xFFFFFFFF, length(s) & 0xFF);
    cb_map_store(token, s);
    return "/cb " + token;
}

// ─── Settings & Config ────────────────────────────────────────────────────────

function settings() {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
}

function get_proxy_args() {
    let cfg = settings();
    if (command_success_from_args(["pidof", "sing-box"])) {
        // If a specific section is configured for the bot, force-select it
        // through the Mihomo REST API so the mixed proxy routes bot traffic
        // through the right outbound.
        let bot_section = cfg.bot_proxy_section ? trim(cfg.bot_proxy_section) : "";
        if (bot_section != "") {
            let tag = bot_section + "-out";
            command_capture(command_from_args([
                "curl", "-s", "-X", "PUT",
                "-H", "Content-Type: application/json",
                "-d", sprintf("%J", { name: tag }),
                "http://127.0.0.1:9090/proxies/GLOBAL"
            ]));
        }
        return [ "--proxy", "http://127.0.0.1:4534" ];
    }
    if (cfg.fallback_socks && trim(cfg.fallback_socks) != "") {
        return [ "--proxy", "socks5h://" + trim(cfg.fallback_socks) ];
    }
    return [];
}

// ─── Telegram API Core ───────────────────────────────────────────────────────

function tg_request(token, method, payload) {
    if (!token) return null;
    let url = "https://api.telegram.org/bot" + token + "/" + method;
    // Pass the JSON body directly to curl's -d argument so there is no temp
    // file to leak: the old /tmp/tg_payload_*.json files were left behind
    // whenever the process was killed mid-request (e.g. during the 20-second
    // getUpdates long-poll on reboot or watchdog restart).
    let body = sprintf("%J", payload);
    let args = [ "curl", "-s", "-m", "35", "--connect-timeout", "10",
                 "-X", "POST", "-H", "Content-Type: application/json",
                 "-d", body ];
    let proxy = get_proxy_args();
    for (let p in proxy) push(args, p);
    push(args, url);
    let res = command_capture(command_from_args(args));
    if (!res || res.status != 0 || res.output == "") return null;
    try { return json(res.output); } catch (e) { return null; }
}

function send_message(token, chat_id, text, parse_mode, keyboard) {
    text = as_string(text);
    if (length(text) > 3900) text = substr(text, 0, 3900) + "\n... (сообщение сокращено)";
    let payload = { chat_id: int(chat_id), text: text };
    if (parse_mode) payload.parse_mode = parse_mode;
    if (keyboard) payload.reply_markup = { inline_keyboard: keyboard };
    return tg_request(token, "sendMessage", payload);
}

function edit_message(token, chat_id, message_id, text, parse_mode, keyboard) {
    text = as_string(text);
    if (length(text) > 3900) text = substr(text, 0, 3900) + "\n... (сообщение сокращено)";
    let payload = { chat_id: int(chat_id), message_id: int(message_id), text: text };
    if (parse_mode) payload.parse_mode = parse_mode;
    if (keyboard) payload.reply_markup = { inline_keyboard: keyboard };
    return tg_request(token, "editMessageText", payload);
}

function send_document(token, chat_id, file_path) {
    if (!token) return null;
    let url = "https://api.telegram.org/bot" + token + "/sendDocument";
    let args = [ "curl", "-s", "-m", "60", "--connect-timeout", "10", "-X", "POST", "-F", "chat_id=" + chat_id, "-F", "document=@" + file_path ];
    let proxy = get_proxy_args();
    for (let p in proxy) push(args, p);
    push(args, url);
    let res = command_capture(command_from_args(args));
    if (!res || res.status != 0 || res.output == "") return null;
    try { return json(res.output); } catch (e) { return null; }
}

function get_file_url(token, file_id) {
    let res = tg_request(token, "getFile", { file_id: file_id });
    if (res && res.ok && res.result && res.result.file_path) {
        return "https://api.telegram.org/file/bot" + token + "/" + res.result.file_path;
    }
    return null;
}

// ─── State Management ────────────────────────────────────────────────────────

// chat_id arrives from untrusted Telegram payloads; keep /tmp paths traversal-safe
function tg_state_path(chat_id) {
    let safe_id = as_string(chat_id);
    if (!match(safe_id, /^-?[0-9]+$/))
        return null;
    return "/tmp/tg_state_" + safe_id + ".json";
}

function get_tg_state(chat_id) {
    let f = tg_state_path(chat_id);
    if (!f) return null;
    let data = fs.readfile(f);
    // A corrupt per-chat state file drops that conversation back to the main
    // menu, which is the same thing a missing file does.
    if (data) { try { return json(data); } catch(e) {} }
    return null;
}

function set_tg_state(chat_id, state_obj) {
    let f = tg_state_path(chat_id);
    if (!f) return;
    // Absent file already satisfies the caller; fs.unlink throws on ENOENT.
    if (state_obj == null) { try { fs.unlink(f); } catch(e) {} }
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
    // Split on whitespace while honoring single/double quotes; shell metacharacters
    // stay literal because they are passed as exact argv to command_from_args().
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

function safe_execute(exec_text) {
    let parsed = parse_command_words(exec_text);
    if (parsed.error || length(parsed.words) == 0)
        return { status: 1, output: "Неверный формат команды" };

    let argv = parsed.words;
    let command_name = argv[0];
    // strip any leading path, e.g. "/sbin/logread" -> "logread"
    let base_match = match(command_name, /([^\/]+)$/);
    let base = base_match ? base_match[1] : command_name;

    let policy = safe_exec_patterns[base];
    if (!policy)
        return { status: 1, output: "Команда '" + base + "' не входит в список разрешённых" };

    let rest = slice(argv, 1);

    if (policy.exact) {
        if (length(rest) != length(policy.args)) return { status: 1, output: "Аргументы не совпадают с разрешённым шаблоном" };
        for (let i = 0; i < length(rest); i++)
            if (rest[i] != policy.args[i]) return { status: 1, output: "Аргументы не совпадают с разрешённым шаблоном" };
    } else {
        if (length(rest) < policy.min_args || length(rest) > policy.max_args) return { status: 1, output: "Неверное число аргументов" };
        // Commands that accept optional flags validate each one against extra_pattern
        if (policy.extra_pattern) {
            for (let arg in rest)
                if (!match(arg, policy.extra_pattern)) return { status: 1, output: "Аргумент не разрешён: " + arg };
        }
        // For tachyon: allow only read-only subcommand verbs
        if (base == "tachyon" && length(rest) == 1) {
            let allowed_sub = { get_status: 1, doctor: 1, show_version: 1, show_sing_box_version: 1, show_config: 1, get_system_info: 1 };
            if (!allowed_sub[rest[0]]) return { status: 1, output: "Подкоманда '" + rest[0] + "' не входит в whitelist" };
        }
    }

    let full_argv = [ policy.bin ];
    for (let a in rest) push(full_argv, a);
    return command_capture(command_from_args(full_argv));
}

function escape_html(text) {
    text = replace(as_string(text), /&/g, "&amp;");
    text = replace(text, /</g, "&lt;");
    text = replace(text, />/g, "&gt;");
    text = replace(text, /"/g, "&quot;");
    return text;
}

function ipv4_to_int(addr) {
    let parts = split(addr, ".");
    if (length(parts) != 4) return 0;
    return (int(parts[0]) << 24) | (int(parts[1]) << 16) | (int(parts[2]) << 8) | int(parts[3]);
}

function cidr_match_v4(target, cidr) {
    let slash = index(cidr, "/");
    if (slash < 0) return target == cidr;
    let cidr_ip = substr(cidr, 0, slash);
    let prefix = int(substr(cidr, slash + 1));
    if (prefix < 0 || prefix > 32) return false;
    let target_int = ipv4_to_int(target);
    let cidr_int = ipv4_to_int(cidr_ip);
    if (target_int == 0 || cidr_int == 0) return false;
    let mask = prefix == 0 ? 0 : (~0 << (32 - prefix));
    return (target_int & mask) == (cidr_int & mask);
}

// ─── Views & Handlers ────────────────────────────────────────────────────────

function format_bytes(b) {
    b = double(b || 0);
    if (b > 1073741824) return sprintf("%.2f GB", b / 1073741824);
    if (b > 1048576) return sprintf("%.2f MB", b / 1048576);
    if (b > 1024) return sprintf("%.2f KB", b / 1024);
    return sprintf("%d B", b);
}


let setting_schema = {
    settings: {
        config_version: "Версия конфига",
        dns_type: "Тип DNS",
        dns_server: "DNS Серверы",
        bootstrap_dns_server: "Bootstrap DNS",
        dns_strategy: "Стратегия DNS",
        dns_detour_enabled: "DNS Detour",
        source_network_interfaces: "Входящие интерфейсы",
        enable_output_network_interface: "Привязка к WAN",
        enable_badwan_interface_monitoring: "Мониторинг WAN",
        enable_yacd: "Панель YACD",
        disable_quic: "Блокировать QUIC",
        list_update_enabled: "Обновление списков",
        component_update_check_enabled: "Обновление ядра",
        download_lists_via_proxy: "Списки через прокси",
        download_components_via_proxy: "Ядро через прокси",
        dont_touch_dhcp: "Не трогать DHCP",
        isolate_p2p: "Изолировать P2P",
        log_level: "Уровень логов",
        exclude_ntp: "Исключить NTP",
        shutdown_correctly: "Корректное завершение",
        smart_detect: "Smart Detect",
        smart_detect_sections: "Секции Smart Detect"
    },
    telegram: {
        enabled: "Бот Включен",
        bot_token: "Токен",
        admin_ids: "Admin IDs",
        poll_interval: "Интервал опроса",
        notify_crash: "Сбои ядра",
        notify_restart: "Перезапуски",
        notify_server_switch: "Переключение серверов",
        notify_subscription: "Статус подписок",
        notify_cert: "Сертификаты",
        notify_dns_leak: "Утечки DNS",
        daily_report_enabled: "Ежедневный отчет",
        daily_report_hour: "Время отчета (час)",
        quiet_hours_enabled: "Тихие часы",
        quiet_hours_start: "Начало тихих часов",
        quiet_hours_end: "Конец тихих часов",
        fallback_socks: "Резервный SOCKS5",
        language: "Язык"
    },
    subscription_url: {
        section: "Секция",
        url: "URL",
        auto_user_agent: "Auto User-Agent",
        user_agent: "User-Agent",
        auto_hwid: "Auto HWID",
        subscription_update_enabled: "Автообновление",
        subscription_update_interval: "Интервал обновления",
        download_via_proxy_enabled: "Через прокси",
        show_dashboard_metadata: "Метаданные подписки",
        prefix_nodes: "Префикс узлов",
        node_prefix: "Строка префикса",
        include_urltest_groups: "Группы URL-Test",
        hide_urltest_group_outbounds: "Скрыть узлы групп",
        hide_detour_outbounds: "Скрыть Detour узлы"
    },
    server: {
        label: "Название",
        enabled: "Включен",
        protocol: "Протокол",
        routing_mode: "Режим"
    }
};

function get_schema_label(stype, key) {
    if (setting_schema[stype] && setting_schema[stype][key]) return setting_schema[stype][key];
    return key;
}

function is_boolean_key(key) {
    let b = ["enabled", "auto_user_agent", "auto_hwid", "subscription_update_enabled",
             "download_via_proxy_enabled", "show_dashboard_metadata", "prefix_nodes",
             "include_urltest_groups", "hide_urltest_group_outbounds", "hide_detour_outbounds",
             "dns_detour_enabled", "enable_output_network_interface", "enable_badwan_interface_monitoring",
             "enable_yacd", "disable_quic", "list_update_enabled", "component_update_check_enabled",
             "download_lists_via_proxy", "download_components_via_proxy", "dont_touch_dhcp",
             "isolate_p2p", "exclude_ntp", "shutdown_correctly", "smart_detect",
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

function view_settings_menu(token, chat_id, msg_id) {
    let text = "⚙️ <b>Все Настройки</b>\n\nВыберите категорию для редактирования:";
    let keyboard = [
        [{ text: "🌍 Глобальные настройки", callback_data: "/set_cat settings settings" }],
        [{ text: "🤖 Настройки Telegram", callback_data: "/set_cat telegram telegram" }],
        [{ text: "🔗 Подписки", callback_data: "/set_list subscription_url" }],
        [{ text: "🖥 Кастомные серверы", callback_data: "/set_list server" }],
        [{ text: "🌐 DNS Серверы (Пресеты)", callback_data: "/dns_presets" }],
        [{ text: "🔕 Тихие часы", callback_data: "/qh" }],
        [{ text: "🔍 Проверка правила", callback_data: "/test_rule" }],
        [{ text: "📤 Экспорт конфига", callback_data: "/export_config" }],
        [{ text: "⬅️ Назад", callback_data: "/menu" }]
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
    push(keyboard, [{ text: "🔙 Категории", callback_data: "/settings" }]);
    let text = "⚙️ <b>Категория: " + stype + "</b>\nВыберите объект:";
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
    
    let text = "⚙️ <b>Редактирование:</b> <code>" + escape_html(sname) + "</code> (" + stype + ")\n\n";
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
    if (start > 0) push(nav, { text: "◀️ Пред", callback_data: "/set_cat " + stype + " " + sname + " " + (page - 1) });
    if (end < total) push(nav, { text: "След ▶️", callback_data: "/set_cat " + stype + " " + sname + " " + (page + 1) });
    if (length(nav) > 0) push(keyboard, nav);
    
    if (stype == "settings" || stype == "telegram") {
        push(keyboard, [{ text: "🔙 Назад", callback_data: "/settings" }]);
    } else {
        push(keyboard, [{ text: "🔙 Назад", callback_data: "/set_list " + stype }]);
    }
    
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function handle_set_tog(token, chat_id, msg_id, stype, sname, key, page) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let s = c.get_all(CONFIG_NAME, sname);
    if (!s) return;
    let b = (s[key] == "1" || s[key] == "true");
    c.set(CONFIG_NAME, sname, key, b ? "0" : "1");
    c.commit(CONFIG_NAME);
    return view_set_cat(token, chat_id, msg_id, stype, sname, page);
}

function view_set_arr(token, chat_id, msg_id, stype, sname, key) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let s = c.get_all(CONFIG_NAME, sname);
    if (!s) return;
    let items = common.list_option(s, key);
    let label = get_schema_label(stype, key);
    
    let text = "⚙️ <b>Список:</b> " + escape_html(label) + "\n\n";
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
    push(keyboard, [{ text: "🔙 Назад", callback_data: "/set_cat " + stype + " " + sname }]);
    
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}


function view_menu(token, chat_id, msg_id) {
    let sys = api.get_system_status();
    let text = "🏠 <b>Tachyon Control Panel</b>\n\n" +
               "Версия: <code>" + sys.tachyon_version + "</code>\n" +
               "Роутер CPU: <code>" + sys.cpu + "</code>\n\n";
               
    let keys_servers = keys(sys.active_servers || {});
    if (length(keys_servers) > 0) {
        text += "Активные серверы:\n";
        for (let i = 0; i < length(keys_servers); i++) {
            let gname = keys_servers[i];
            let srv = sys.active_servers[gname];
            text += "└ " + escape_html(gname) + ": <code>" + escape_html(srv.server) + "</code>\n";
        }
        text += "\n";
    } else {
         text += "Активный сервер: <code>Не выбран</code>\n\n";
    }

    text += "Выберите раздел для управления:";
               
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
            { text: "⚡ Speedtest", callback_data: "/speed" },
            { text: "📍 Ping", callback_data: "/ping" }
        ],
        [
            { text: "🩺 Диагностика", callback_data: "/test" },
            { text: "🔗 Подключения", callback_data: "/connections" }
        ],
        [
            { text: "📋 Логи", callback_data: "/logs" },
            { text: "ℹ️ Инфо", callback_data: "/info" }
        ],
        [
            { text: "🤖 ИИ-Самолечение", callback_data: "/heal" },
            { text: "🎮 Игровой QoS", callback_data: "/qos" }
        ],
        [
            { text: "⚙️ Все Настройки", callback_data: "/settings" },
            { text: "📖 Справка", callback_data: "/help" }
        ]
    ];
    
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_status(token, chat_id, msg_id) {
    let sys = api.get_system_status();
    let conn = api.check_connection();
    let text = "📊 <b>Статус Системы</b>\n\n" +
               "Версия: <code>" + (sys.tachyon_version || "?") + "</code>\n" +
               "Аптайм: <code>" + sys.uptime + "</code>\n" +
               "CPU: <code>" + sys.cpu + "</code>\n" +
               "RAM: <code>" + sys.ram_avail + "MB / " + sys.ram_total + "MB</code>\n\n" +
               "sing-box: <code>" + sys.singbox + "</code>\n" +
               "Watchdog: <code>" + (sys.watchdog_running ? "🟢 running" : "🔴 stopped") + "</code>\n\n" +
               "WAN: <code>" + (sys.wan_ip || "?") + "</code> " +
               (conn && conn.direct ? "✅" : "❌") + "\n" +
               "Proxy: " + (conn && conn.proxy ? "✅ reachable" : "❌ unreachable") + "\n" +
               "LAN: <code>" + (sys.lan_ip || "?") + "</code>\n";

    if (sys.pause_remaining > 0) {
        text += "\n⏸ Пауза: " + as_string(sys.pause_remaining) + " сек.\n";
    }

    let keys_servers = keys(sys.active_servers || {});
    if (length(keys_servers) > 0) {
        text += "\nАктивные серверы:\n";
        for (let i = 0; i < length(keys_servers); i++) {
            let gname = keys_servers[i];
            let srv = sys.active_servers[gname];
            let lat = srv.latency != "N/A" ? " (" + srv.latency + " ms)" : "";
            text += "└ " + escape_html(gname) + ": <code>" + escape_html(srv.server) + lat + "</code>\n";
        }
    }

    let keyboard = [
        [
            { text: "⚡ Speedtest", callback_data: "/speed" },
            { text: "📍 Ping", callback_data: "/ping" }
        ],
        [
            { text: "🔄 Обновить", callback_data: "/status" },
            { text: "🩺 Тест", callback_data: "/test" }
        ],
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

function view_outbounds(token, chat_id, msg_id, group_name) {
    let data = api.get_clash_proxies_data();
    if (!data || !data.proxies) {
        let err = "❌ Не удалось получить список серверов.";
        if (msg_id) edit_message(token, chat_id, msg_id, err, "HTML", [[{text:"⬅️ Назад", callback_data:"/menu"}]]);
        else send_message(token, chat_id, err, "HTML", [[{text:"⬅️ Назад", callback_data:"/menu"}]]);
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
        let err = "❌ Группы прокси не найдены.";
        if (msg_id) edit_message(token, chat_id, msg_id, err, "HTML", [[{text:"⬅️ Назад", callback_data:"/menu"}]]);
        else send_message(token, chat_id, err, "HTML", [[{text:"⬅️ Назад", callback_data:"/menu"}]]);
        return;
    }
    
    if (length(groups) == 1 && !group_name) {
        group_name = groups[0];
    }
    
    let text = "🌐 <b>Outbounds (Серверы)</b>\n\n";
    let keyboard = [];
    
    if (!group_name) {
        text += "Выберите группу для настройки сервера:\n\n";
        for (let i = 0; i < length(groups); i++) {
            let gname = groups[i];
            let active = data.proxies[gname].now || "none";
            text += "• <b>" + escape_html(gname) + "</b>: <code>" + escape_html(active) + "</code>\n";
            push(keyboard, [{ text: "🌐 " + gname, callback_data: "/outbounds " + gname }]);
        }
        push(keyboard, [{ text: "🔄 Обновить", callback_data: "/outbounds" }]);
        push(keyboard, [{ text: "⬅️ Назад", callback_data: "/menu" }]);
    } else {
        let group_data = data.proxies[group_name];
        if (!group_data) return view_outbounds(token, chat_id, msg_id);
        
        text += "Группа: <b>" + escape_html(group_name) + "</b>\n\n";
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
                push(row, { text: (name == active_server ? "🔵 " : "") + name, callback_data: "/sw " + group_name + " " + name });
                if (length(row) == 2) {
                    push(keyboard, row);
                    row = [];
                }
                count++;
            }
        }
        if (length(row) > 0) push(keyboard, row);
        
        if (count == 0) text += "<i>Серверы не найдены.</i>\n";
        else text += "\nℹ️ Нажмите кнопку, чтобы переключить сервер.";
        
        push(keyboard, [{ text: "🔄 Обновить", callback_data: "/outbounds " + group_name }]);
        if (length(groups) > 1) {
            push(keyboard, [{ text: "🔙 К списку групп", callback_data: "/outbounds" }]);
        } else {
            push(keyboard, [{ text: "⬅️ Назад", callback_data: "/menu" }]);
        }
    }
    
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function handle_switch(token, chat_id, msg_id, group_name, server_name) {
    api.clash_request("PUT", "proxies/" + group_name, { name: server_name });
    // A successful switch answers 204 with an empty body, which clash_request()
    // cannot distinguish from a failure — so verify by reading the state back.
    let data = api.get_clash_proxies_data();
    let grp = (data && data.proxies) ? data.proxies[group_name] : null;
    if (!grp || grp.now != server_name) {
        send_message(token, chat_id,
            "⚠️ <b>Не удалось переключить сервер</b>\n" +
            "Группа: <code>" + escape_html(group_name) + "</code>\n" +
            "Сервер: <code>" + escape_html(server_name) + "</code>\n\n" +
            "Проверьте, запущен ли sing-box и доступен ли Clash API.", "HTML");
    }
    view_outbounds(token, chat_id, msg_id, group_name);
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
                push(keyboard, [{ text: "❌ Удалить " + it.val, callback_data: cb_data(["/sec_del_it", sec_name, it.type, it.val]) }]);
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
    let res = command_capture(command_from_args([ "/usr/bin/tachyon", "doctor" ]));
    let report = res ? (res.output || "Нет вывода диагностики.") : "Ошибка запуска диагностики.";
    if (length(report) > 3500) report = substr(report, 0, 3500) + "\n... (отчёт сокращён)";
    send_message(token, chat_id, "🩺 <b>Результаты Tachyon Doctor:</b>\n\n<pre>" + escape_html(report) + "</pre>", "HTML", [[{text:"⬅️ Назад", callback_data:"/menu"}]]);
}

function exec_restart(token, chat_id) {
    let text = "⚠️ <b>Перезапустить службы Tachyon?</b>\nТекущие соединения будут разорваны на время перезапуска.";
    let keyboard = [
        [{ text: "✅ Да, перезапустить", callback_data: "/confirm_restart" }],
        [{ text: "⬅️ Отмена", callback_data: "/menu" }]
    ];
    send_message(token, chat_id, text, "HTML", keyboard);
}

function apply_confirmed_restart(token, chat_id, msg_id) {
    edit_message(token, chat_id, msg_id, "🔄 <b>Перезапускаю службы Tachyon...</b>", "HTML");
    let st = command_status(command_from_args(["/usr/bin/tachyon", "restart"]));
    let text = (st == 0) ? "✅ <b>Перезапуск выполнен успешно!</b>" : "❌ <b>Ошибка при перезапуске.</b>";
    send_message(token, chat_id, text, "HTML", [[{text:"⬅️ Меню", callback_data:"/menu"}]]);
}

// ─── Backup restore: safe extraction, UCI validation, rollback ───────────────

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
        // Reject absolute paths, ".." traversal, and unexpected members
        if (substr(m, 0, 1) == "/") return { ok: false, reason: "absolute path: " + m };
        if (match(m, /\.\./)) return { ok: false, reason: "path traversal: " + m };
        if (m != "config/tachyon" && !match(m, /^tachyon\//))
            return { ok: false, reason: "unexpected member: " + m };
    }
    return { ok: true };
}

function backup_extract_dir() {
    let ts = time();
    // ucode has no Math global; clock()[1] (microseconds) is what the rest of the
    // codebase uses to make temp paths unique.
    let rand = sprintf("%04x", clock()[1] & 0xFFFF);
    let dir = "/etc/.tachyon/restore_" + as_string(ts) + "_" + rand;
    system("mkdir -p " + shell_quote(dir) + " 2>/dev/null");
    return dir;
}

function config_sane_preview(path) {
    let data = fs.readfile(path);
    if (data == null) return false;
    // Minimal UCI sanity: must contain at least one "config <type> '<name>'" line
    return match(data, /(^|\n)[ \t]*config[ \t]+[A-Za-z0-9_-]+/) != null;
}

function restore_config_from_backup(backup_path) {
    if (backup_path && fs.stat(backup_path)) {
        let tmp = "/etc/config/tachyon.restore-tmp";
        system(command_from_args([ "cp", "-a", backup_path, tmp ]) + " >/dev/null 2>&1");
        system(command_from_args([ "mv", "-f", tmp, "/etc/config/tachyon" ]) + " >/dev/null 2>&1");
    }
}

function apply_backup_restore(token, chat_id, dl_path) {
    let members = backup_archive_members(dl_path);
    if (length(members) == 0) {
        fs.unlink(dl_path);
        send_message(token, chat_id, "❌ <b>Архив пуст или повреждён.</b>", "HTML", [[{text:"⬅️ Меню", callback_data:"/menu"}]]);
        return;
    }

    let safety = backup_archive_safe(members);
    if (!safety.ok) {
        fs.unlink(dl_path);
        send_message(token, chat_id, "❌ <b>Небезопасный архив:</b> " + escape_html(safety.reason), "HTML", [[{text:"⬅️ Меню", callback_data:"/menu"}]]);
        return;
    }

    send_message(token, chat_id, "🔄 <b>Проверяю и восстанавливаю бэкап...</b>", "HTML");

    let stage = backup_extract_dir();
    command_status(command_from_args([ "rm", "-rf", stage ]));
    if (command_status(command_from_args([ "mkdir", "-p", stage ])) != 0 ||
        command_status(command_from_args([ "tar", "-xzf", dl_path, "-C", stage ])) != 0) {
        command_status(command_from_args([ "rm", "-rf", stage ]));
        fs.unlink(dl_path);
        send_message(token, chat_id, "❌ <b>Не удалось распаковать архив.</b>", "HTML", [[{text:"⬅️ Меню", callback_data:"/menu"}]]);
        return;
    }
    fs.unlink(dl_path);

    let staged_config = stage + "/config/tachyon";
    let had_config = fs.stat(staged_config) != null;
    if (had_config && !config_sane_preview(staged_config)) {
        command_status(command_from_args([ "rm", "-rf", stage ]));
        send_message(token, chat_id, "❌ <b>config/tachyon в архиве не похож на валидный UCI.</b>", "HTML", [[{text:"⬅️ Меню", callback_data:"/menu"}]]);
        return;
    }

    let staged_data = stage + "/tachyon";
    let had_data = fs.stat(staged_data) != null;
    if (!had_config && !had_data) {
        command_status(command_from_args([ "rm", "-rf", stage ]));
        send_message(token, chat_id, "❌ <b>В архиве нет ни config/tachyon, ни каталога tachyon/.</b>", "HTML", [[{text:"⬅️ Меню", callback_data:"/menu"}]]);
        return;
    }

    // Snapshot live targets so a failed reload can be rolled back
    let cfg_backup = "/etc/.tachyon/restore_cfg_backup." + as_string(time());
    if (fs.stat("/etc/config/tachyon")) {
        if (command_status(command_from_args([ "cp", "-a", "/etc/config/tachyon", cfg_backup ])) != 0) {
            command_status(command_from_args([ "rm", "-rf", stage ]));
            send_message(token, chat_id, "❌ <b>Не удалось сохранить текущий конфиг.</b>", "HTML", [[{text:"⬅️ Меню", callback_data:"/menu"}]]);
            return;
        }
    }
    let data_backup = "/etc/.tachyon/restore_data_backup." + as_string(time());
    if (fs.stat("/etc/tachyon")) {
        if (command_status(command_from_args([ "cp", "-a", "/etc/tachyon", data_backup ])) != 0) {
            command_status(command_from_args([ "rm", "-f", cfg_backup ]));
            command_status(command_from_args([ "rm", "-rf", stage ]));
            send_message(token, chat_id, "❌ <b>Не удалось сохранить текущие данные /etc/tachyon.</b>", "HTML", [[{text:"⬅️ Меню", callback_data:"/menu"}]]);
            return;
        }
    }

    // Apply staged config
    if (had_config) {
        if (command_status(command_from_args([ "cp", "-a", staged_config, "/etc/config/tachyon.restored" ])) != 0 ||
            command_status(command_from_args([ "mv", "/etc/config/tachyon.restored", "/etc/config/tachyon" ])) != 0) {
            restore_config_from_backup(cfg_backup);
            command_status(command_from_args([ "rm", "-rf", stage ]));
            send_message(token, chat_id, "❌ <b>Ошибка записи /etc/config/tachyon.</b>", "HTML", [[{text:"⬅️ Меню", callback_data:"/menu"}]]);
            return;
        }
        command_status(command_from_args([ "chmod", "600", "/etc/config/tachyon" ]));
        // Validate through the real UCI parser
        if (command_status(command_from_args([ "/sbin/uci", "show", "tachyon" ])) != 0) {
            restore_config_from_backup(cfg_backup);
            command_status(command_from_args([ "rm", "-rf", stage, data_backup, cfg_backup ]));
            send_message(token, chat_id, "❌ <b>Восстановленный конфиг не прошёл проверку UCI. Выполнен откат.</b>", "HTML", [[{text:"⬅️ Меню", callback_data:"/menu"}]]);
            return;
        }
    }

    // Apply staged data directory
    if (had_data) {
        command_status(command_from_args([ "rm", "-rf", "/etc/tachyon" ]));
        if (command_status(command_from_args([ "cp", "-a", staged_data, "/etc/tachyon" ])) != 0) {
            command_status(command_from_args([ "rm", "-rf", "/etc/tachyon" ]));
            if (fs.stat(data_backup))
                command_status(command_from_args([ "mv", data_backup, "/etc/tachyon" ]));
            restore_config_from_backup(cfg_backup);
            command_status(command_from_args([ "rm", "-rf", stage ]));
            send_message(token, chat_id, "❌ <b>Ошибка записи /etc/tachyon. Выполнен откат.</b>", "HTML", [[{text:"⬅️ Меню", callback_data:"/menu"}]]);
            return;
        }
    }

    command_status(command_from_args([ "rm", "-rf", stage ]));
    command_status(command_from_args([ "rm", "-f", cfg_backup ]));
    command_status(command_from_args([ "rm", "-rf", data_backup ]));

    send_message(token, chat_id, "✅ <b>Бэкап восстановлен. Перезапускаю Tachyon...</b>", "HTML");
    command_status(command_from_args([ "/usr/bin/tachyon", "restart" ]));
    send_message(token, chat_id, "✅ <b>Готово!</b>", "HTML", [[{text:"⬅️ Меню", callback_data:"/menu"}]]);
}

function exec_backup(token, chat_id) {
    send_message(token, chat_id, "⏳ <b>Собираю бэкап...</b>", "HTML");
    let file_path = "/etc/.tachyon/backup.tar.gz";
    command_status(command_from_args([ "tar", "-czf", file_path, "-C", "/etc", "config/tachyon", "tachyon" ]) + " 2>/dev/null");

    if (fs.stat(file_path)) {
        send_document(token, chat_id, file_path);
        fs.unlink(file_path);
    } else {
        send_message(token, chat_id, "❌ <b>Ошибка создания бэкапа.</b>", "HTML", [[{text:"⬅️ Меню", callback_data:"/menu"}]]);
    }
}

function exec_support_bundle(token, chat_id) {
    send_message(token, chat_id, "⏳ <b>Формирую Support Bundle...</b>", "HTML");
    system(command_from_args([ "ip", "route" ]) + " > /etc/.tachyon/ip_route.txt");
    system(command_from_args([ "logread" ]) + " > /etc/.tachyon/logread.txt");
    let file_path = "/etc/.tachyon/support_bundle.tar.gz";
    command_status(command_from_args([ "tar", "-czf", file_path, "/etc/config/tachyon", "/var/etc/tachyon", "/etc/config/network", "/etc/config/firewall", "/tmp/dhcp.leases", "/etc/.tachyon/ip_route.txt", "/etc/.tachyon/logread.txt" ]) + " 2>/dev/null");
    
    if (fs.stat(file_path)) {
        send_document(token, chat_id, file_path);
        fs.unlink(file_path);
    } else {
        send_message(token, chat_id, "❌ <b>Ошибка генерации Bundle.</b>", "HTML");
    }
    // Absent file already satisfies the caller; fs.unlink throws on ENOENT.
    try { fs.unlink("/etc/.tachyon/ip_route.txt"); fs.unlink("/etc/.tachyon/logread.txt"); } catch(e) {}
}

function exec_close_connections(token, chat_id) {
    let out = command_capture(command_from_args(["curl", "-s", "-X", "DELETE", "http://127.0.0.1:4534/connections"]));
    if (out && out.status == 0)
        send_message(token, chat_id, "✅ <b>Все активные соединения сброшены.</b>\nОни будут переустановлены по новым маршрутам.", "HTML", [[{text:"⬅️ Меню", callback_data:"/menu"}]]);
    else
        send_message(token, chat_id, "❌ <b>Ошибка сброса соединений.</b>\nsing-box Clash API недоступен.", "HTML", [[{text:"⬅️ Меню", callback_data:"/menu"}]]);
}

// A rebuild published under an existing tag keeps its version, so "1.2.66 ➡️
// 1.2.66" is all the version fields can say. These helpers name the build
// instead: the commit SHA when the release carries one, else the fingerprint
// derived from publish timestamps and asset size.
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

function exec_check_updates(token, chat_id, msg_id) {
    let out = command_output_from_args(["/usr/bin/tachyon", "component_update_check_cache"]);
    let text = "📦 <b>Обновления компонентов</b>\n\n";
    let keyboard = [];
    if (out && out != "") {
        try {
            let data = json(out);
            let results = data.results || [];
            let has_updates = false;
            if (!data.enabled) {
                text += "ℹ️ Проверка обновлений отключена в настройках.";
            } else if (length(results) == 0) {
                text += "ℹ️ Кэш пуст. Зайдите позже — проверка обновлений запускается автоматически.";
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
                        text += "• <b>" + title + "</b>: <code>" + cur + "</code> — новая сборка релиза" +
                            (transition != "" ? " " + transition : "") + " ⚠️\n";
                        push(keyboard, [{text: "🔄 Обновить " + title, callback_data: "/update_component " + name}]);
                        has_updates = true;
                    } else if (comp.status == "outdated") {
                        text += "• <b>" + title + "</b>: <code>" + cur + "</code> ➡️ <code>" + lat + "</code> ⚠️\n";
                        push(keyboard, [{text: "🔄 Обновить " + title, callback_data: "/update_component " + name}]);
                        has_updates = true;
                    } else if (comp.status == "dev") {
                        text += "• <b>" + title + "</b>: <code>" + cur + "</code> 🧪 dev-сборка\n";
                    } else {
                        text += "• <b>" + title + "</b>: <code>" + cur + "</code> ✅\n";
                    }
                }
                if (!has_updates) text += "\n✅ Все компоненты актуальны.";
            }
        } catch(e) {
            text += "❌ Ошибка парсинга кэша: " + e;
        }
    } else {
        text += "ℹ️ Кэш проверок пуст или недоступен.\nЗайдите позже или включите проверку обновлений в UI.";
    }
    
    push(keyboard, [{ text: "🔄 Обновить кэш", callback_data: "/check_updates" }]);
    push(keyboard, [{ text: "⬅️ Назад", callback_data: "/menu" }]);
    
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_instances(token, chat_id, msg_id) {
    let res = command_capture(command_from_args(["curl", "-s", "http://127.0.0.1:4534/proxies"]));
    let text = "🖧 <b>Live Server Instances</b>\n\n";
    if (res && res.status == 0 && res.output) {
        try {
            let data = json(res.output);
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
            if (count == 0) text += "Серверы не найдены или sing-box не запущен.";
        } catch(e) {
            text += "Ошибка парсинга API: " + e;
        }
    } else {
        text += "❌ Не удалось подключиться к API sing-box.";
    }
    
    let kb = [[
        {text: "🔄 Обновить", callback_data: "/instances"},
        {text: "⬅️ Назад", callback_data: "/status"}
    ]];
    
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", kb);
    else send_message(token, chat_id, text, "HTML", kb);
}

// ─── Phase 1: Speed, Ping, Improved Status ─────────────────────────────────

function exec_speedtest(token, chat_id, msg_id) {
    let wait_text = "⚡ <b>Запуск Speedtest...</b>\n\nТестирую скорость через Cloudflare. Это займёт до 30 секунд.";
    if (msg_id) edit_message(token, chat_id, msg_id, wait_text, "HTML");
    else send_message(token, chat_id, wait_text, "HTML");

    let result = api.run_speedtest();
    let text = "⚡ <b>Результат Speedtest</b>\n\n";
    if (result) {
        // A failed transfer yields 0 bytes/s; report that as an error instead of "0.0 Mbps"
        text += "📥 Прямое соединение: " +
            (result.direct_mbps > 0
                ? "<code>" + sprintf("%.1f", result.direct_mbps) + " Mbps</code>\n"
                : "❌ не удалось измерить\n");
        text += "📤 Через прокси: " +
            (result.proxy_mbps > 0
                ? "<code>" + sprintf("%.1f", result.proxy_mbps) + " Mbps</code>\n"
                : "❌ не удалось измерить\n");
        if (result.direct_mbps <= 0 && result.proxy_mbps <= 0)
            text += "\n<i>Проверьте доступ в интернет и работу sing-box.</i>\n";
    } else {
        text += "❌ Не удалось выполнить тест. Проверьте, запущен ли sing-box.\n";
    }

    let keyboard = [
        [{ text: "⚡ Ещё раз", callback_data: "/speed" }],
        [{ text: "⬅️ Назад", callback_data: "/status" }]
    ];
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_ping(token, chat_id, msg_id) {
    let text = "📍 <b>Задержка до серверов</b>\n\n";
    let data = api.get_clash_proxies_data();
    if (!data || !data.proxies) {
        text += "❌ Не удалось получить данные из Clash API.";
        let keyboard = [[{ text: "🔄 Обновить", callback_data: "/ping" }, { text: "⬅️ Назад", callback_data: "/status" }]];
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
    if (shown == 0) text += "Нет данных о задержках. Нажмите «Обновить».";

    let keyboard = [
        [{ text: "🔄 Обновить", callback_data: "/ping" }],
        [{ text: "⬅️ Назад", callback_data: "/status" }]
    ];
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

// ─── Phase 2: Quick Test, Logs, System Info ────────────────────────────────

function view_quick_test(token, chat_id, msg_id) {
    let text = "🩺 <b>Быстрая диагностика</b>\n\n";
    let conn = api.check_connection();
    let sys = api.get_system_status();

    text += (conn && conn.direct ? "✅" : "❌") + " Прямое соединение\n";
    text += (conn && conn.proxy ? "✅" : "❌") + " Прокси соединение\n";
    text += (sys && sys.singbox_running ? "✅" : "❌") + " sing-box процесс\n";
    text += (sys && sys.tachyon_running ? "✅" : "❌") + " Tachyon сервис\n";
    text += (sys && sys.watchdog_running ? "✅" : "❌") + " Watchdog\n";

    let nft = command_capture(command_from_args(["/usr/sbin/nft", "list", "tables"]));
    text += (nft && nft.status == 0 && match(nft.output || "", /ip tachyon/)) ? "✅" : "❌";
    text += " nftables правила\n";

    let dns_ok = false;
    try {
        let dns_res = command_capture(command_from_args(["nslookup", "google.com", "127.0.0.1"]));
        dns_ok = dns_res && dns_res.status == 0;
    }
    catch (e) {
        // dns_ok stays false, which is what the report line below prints. A
        // failing DNS check and a failing nslookup invocation mean the same
        // thing to the reader.
    }
    text += (dns_ok ? "✅" : "❌") + " DNS на роутере\n";

    if (sys && sys.pause_remaining > 0) {
        text += "\n⏸ Пауза активна: " + as_string(sys.pause_remaining) + " сек.";
    }

    let keyboard = [
        [{ text: "🔄 Повторить", callback_data: "/test" }],
        [{ text: "⬅️ Назад", callback_data: "/menu" }]
    ];
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_logs(token, chat_id, msg_id, level, count) {
    level = level || "all";
    count = int(count || "30");

    let text = "📋 <b>Логи Tachyon</b> (уровень: " + level + ", последние " + count + ")\n\n<pre>";

    let args = ["/sbin/logread"];
    let res = command_capture(command_from_args(args));
    if (res && res.status == 0 && res.output) {
        let lines = split(res.output, "\n");
        let filtered = [];
        for (let line in lines) {
            if (line == "") continue;
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
        if (length(filtered) == 0) text += "Нет записей для данного уровня.\n";
    } else {
        text += "Не удалось прочитать логи.\n";
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
        [{ text: "🔄 Обновить", callback_data: "/logs " + level + " " + as_string(count) }],
        [{ text: "⬅️ Назад", callback_data: "/menu" }]
    ];
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_system_info(token, chat_id, msg_id) {
    let text = "ℹ️ <b>Информация о системе</b>\n\n";
    let res = command_capture(command_from_args(["/usr/lib/tachyon/diagnostics/runtime.uc", "get-system-info"]));
    if (res && res.status == 0 && res.output) {
        try {
            let info = json(res.output);
            text += "📱 Устройство: <code>" + as_string(info.device_model || "N/A") + "</code>\n";
            text += "💻 OpenWrt: <code>" + as_string(info.openwrt_version || "N/A") + "</code>\n\n";
            text += "🔧 Tachyon: <code>" + as_string(info.tachyon_version || "N/A") + "</code>\n";
            text += "📱 LuCI App: <code>" + as_string(info.luci_app_version || "N/A") + "</code>\n\n";
            text += "📦 sing-box: <code>" + as_string(info.sing_box_version || "N/A") + "</code>\n";
            if (info.sing_box_extended) text += "   Extended: ✅\n";
            if (info.sing_box_tiny) text += "   Tiny: ✅\n";
            if (info.sing_box_tailscale) text += "   Tailscale: ✅\n";
            text += "\n";
            if (info.zapret_installed == "1") text += "🛡 Zapret: <code>" + as_string(info.zapret_version || "?") + "</code>\n";
            if (info.zapret2_installed == "1") text += "🛡 Zapret2: <code>" + as_string(info.zapret2_version || "?") + "</code>\n";
            if (info.byedpi_installed == "1") text += "🛡 ByeDPI: <code>" + as_string(info.byedpi_version || "?") + "</code>\n";
        } catch(e) {
            text += "Ошибка чтения информации: " + e;
        }
    } else {
        text += "❌ Не удалось получить информацию о системе.";
    }

    let keyboard = [
        [{ text: "🔄 Обновить", callback_data: "/info" }],
        [{ text: "⬅️ Назад", callback_data: "/menu" }]
    ];
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

// ─── Phase 3: Connections, Help ────────────────────────────────────────────

function view_connections(token, chat_id, msg_id, page) {
    page = int(page || 0);
    if (page < 0) page = 0;
    let data = api.get_clash_connections();
    let text = "🔗 <b>Активные подключения</b>\n\n";

    if (!data || !data.connections || length(data.connections) == 0) {
        text += "Нет активных подключений.";
        let keyboard = [
            [{ text: "🔄 Обновить", callback_data: "/connections" }],
            [{ text: "⬅️ Назад", callback_data: "/menu" }]
        ];
        if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
        else send_message(token, chat_id, text, "HTML", keyboard);
        return;
    }

    text += "📥 Всего скачано: <code>" + format_bytes(data.downloadTotal) + "</code>\n";
    text += "📤 Всего отдано: <code>" + format_bytes(data.uploadTotal) + "</code>\n";
    text += "🔗 Соединений: <code>" + length(data.connections) + "</code>\n\n";

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

    let total_pages = (total + per_page - 1) / per_page;
    let keyboard = [];
    if (total_pages > 1) {
        let nav = [];
        if (page > 0) push(nav, { text: "◀️ Prev", callback_data: "/connections " + as_string(page - 1) });
        push(nav, { text: as_string(page + 1) + "/" + as_string(int(total_pages)), callback_data: "/noop" });
        if (end < total) push(nav, { text: "▶️ Next", callback_data: "/connections " + as_string(page + 1) });
        push(keyboard, nav);
    }
    push(keyboard, [{ text: "🔄 Обновить", callback_data: "/connections" }]);
    push(keyboard, [{ text: "❌ Закрыть все", callback_data: "/close_connections" }]);
    push(keyboard, [{ text: "⬅️ Назад", callback_data: "/menu" }]);

    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_help(token, chat_id, msg_id) {
    let text = "📖 <b>Справка по командам</b>\n\n" +
        "<b>Основные:</b>\n" +
        "/status — Статус системы\n" +
        "/runtime — Статистика трафика\n" +
        "/outbounds — Прокси серверы\n" +
        "/sections — Секции маршрутизации\n" +
        "/devices — Устройства в сети\n" +
        "/instances — Live серверы\n\n" +
        "<b>Диагностика:</b>\n" +
        "/speed — Тест скорости\n" +
        "/ping — Задержка до серверов\n" +
        "/test — Быстрая диагностика\n" +
        "/doctor — Полная диагностика\n" +
        "/logs — Просмотр логов\n" +
        "/info — Информация о системе\n" +
        "/connections — Активные подключения\n\n" +
        "<b>Управление:</b>\n" +
        "/restart — Перезапуск служб Tachyon\n" +
        "/backup — Бэкап конфига\n" +
        "/close_connections — Закрыть все соединения\n" +
        "/check_updates — Проверить обновления\n\n" +
        "<b>Настройка:</b>\n" +
        "/settings — Все настройки\n" +
        "/dns_presets — DNS пресеты\n" +
        "/help — Эта справка";

    let keyboard = [[{ text: "⬅️ Меню", callback_data: "/menu" }]];
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

// ─── Phase 4: Quiet Hours, Rule Test, Export ───────────────────────────────

function view_quiet_hours(token, chat_id, msg_id) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let s = c.get_all(CONFIG_NAME, "telegram");
    let enabled = option(s, "quiet_hours_enabled", "0") == "1";
    let start_hr = option(s, "quiet_hours_start", "23");
    let end_hr = option(s, "quiet_hours_end", "7");

    let text = "🔕 <b>Тихие часы</b>\n\n" +
        "Статус: " + (enabled ? "🟢 Включены" : "❌ Выключены") + "\n" +
        "Начало: <code>" + start_hr + ":00</code>\n" +
        "Конец: <code>" + end_hr + ":00</code>\n\n" +
        "В тихие часы бот отправляет только критические уведомления.";

    let keyboard = [
        [{ text: (enabled ? "❌ Выключить" : "✅ Включить"), callback_data: "/qh_toggle" }],
        [{ text: "⏰ Начало: " + start_hr, callback_data: "/qh_start" }],
        [{ text: "⏰ Конец: " + end_hr, callback_data: "/qh_end" }],
        [{ text: "⬅️ Назад", callback_data: "/settings" }]
    ];
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function handle_qh_toggle(token, chat_id, msg_id) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let s = c.get_all(CONFIG_NAME, "telegram");
    let current = option(s, "quiet_hours_enabled", "0");
    c.set(CONFIG_NAME, "telegram", "quiet_hours_enabled", current == "1" ? "0" : "1");
    c.commit(CONFIG_NAME);
    return view_quiet_hours(token, chat_id, msg_id);
}

function view_test_rule(token, chat_id, msg_id, target) {
    if (!target) {
        set_tg_state(chat_id, { action: "test_rule" });
        return send_message(token, chat_id, "🔍 Введите домен или IP для проверки:\n\n<i>Отправьте /cancel для отмены</i>", "HTML");
    }

    let text = "🔍 <b>Проверка правила:</b> <code>" + escape_html(target) + "</code>\n\n";
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
                text += "✅ Совпадение: <code>" + escape_html(sec[".name"]) + "</code> (domain_suffix)\n";
                text += "   Действие: <code>" + as_string(sec.action || "proxy") + "</code>\n\n";
                matched = true;
            }
        }
        for (let d in domain) {
            if (target == d || target == "full:" + d) {
                text += "✅ Совпадение: <code>" + escape_html(sec[".name"]) + "</code> (domain)\n";
                text += "   Действие: <code>" + as_string(sec.action || "proxy") + "</code>\n\n";
                matched = true;
            }
        }
        for (let ip in ip_cidr) {
            if (match(target, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) && cidr_match_v4(target, ip)) {
                text += "✅ Совпадение: <code>" + escape_html(sec[".name"]) + "</code> (ip_cidr)\n";
                text += "   Действие: <code>" + as_string(sec.action || "proxy") + "</code>\n\n";
                matched = true;
            }
        }
    }

    if (!matched) text += "❌ Совпадений не найдено. Трафик пойдёт через default route.";

    let keyboard = [
        [{ text: "🔄 Ещё раз", callback_data: "/test_rule" }],
        [{ text: "⬅️ Назад", callback_data: "/menu" }]
    ];
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function exec_export_config(token, chat_id, msg_id) {
    let wait_text = "📤 <b>Экспорт конфига...</b>\n";
    if (msg_id) edit_message(token, chat_id, msg_id, wait_text, "HTML");
    else send_message(token, chat_id, wait_text, "HTML");

    let export_path = "/tmp/tachyon_export_" + time() + ".json";
    let res = command_capture(command_from_args(["/usr/lib/tachyon/diagnostics/runtime.uc", "show-config"]));
    if (res && res.status == 0 && res.output) {
        fs.writefile(export_path, res.output);
        send_document(token, chat_id, export_path);
        // Absent file already satisfies the caller; fs.unlink throws on ENOENT.
        try { fs.unlink(export_path); } catch(e) {}
        send_message(token, chat_id, "✅ Конфиг экспортирован.\n\n⚠️ Файл содержит чувствительные данные. Не публикуйте его.", "HTML", [[{ text: "⬅️ Меню", callback_data: "/menu" }]]);
    } else {
        send_message(token, chat_id, "❌ Не удалось экспортировать конфиг.", "HTML", [[{ text: "⬅️ Меню", callback_data: "/menu" }]]);
    }
}

// ─── Device blocking (real firewall rules) ──────────────────────────────────
//
// view_devices() reports a device as blocked when a firewall REJECT rule carries
// its src_mac, so the toggle has to create/remove exactly such a rule. The old
// implementation wrote tachyon.settings.blocked_macs, which nothing ever read.

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

function handle_toggle_mac(token, chat_id, mac_raw) {
    let mac = normalize_mac(mac_raw);
    if (!mac) {
        send_message(token, chat_id, "❌ Некорректный MAC-адрес.", "HTML");
        return view_devices(token, chat_id, null);
    }

    let c = uci_core.cursor();
    if (!c) {
        return send_message(token, chat_id, "❌ Не удалось открыть конфигурацию firewall.", "HTML",
            [[{ text: "⬅️ Меню", callback_data: "/menu" }]]);
    }
    c.load("firewall");

    let existing = find_mac_block_rules(c, mac);
    let blocked_now;
    if (length(existing) > 0) {
        for (let name in existing)
            c.delete("firewall", name);
        blocked_now = false;
    } else {
        let sec = c.add("firewall", "rule");
        if (!sec) {
            return send_message(token, chat_id, "❌ Не удалось создать правило блокировки.", "HTML",
                [[{ text: "⬅️ Меню", callback_data: "/menu" }]]);
        }
        c.set("firewall", sec, "name", "Tachyon block " + mac);
        c.set("firewall", sec, "src", "lan");
        c.set("firewall", sec, "dest", "*");
        c.set("firewall", sec, "proto", "all");
        c.set("firewall", sec, "src_mac", mac);
        c.set("firewall", sec, "target", "REJECT");
        blocked_now = true;
    }
    c.commit("firewall");
    // Reload in the background so the poll loop is not blocked by fw4
    system(common.background_command("/etc/init.d/firewall reload"));

    send_message(token, chat_id,
        (blocked_now ? "🚫 Устройство <code>" : "🔓 Устройство <code>") + mac +
        (blocked_now ? "</code> заблокировано." : "</code> разблокировано.") +
        "\n\n<i>Правила firewall применяются в фоне (несколько секунд).</i>", "HTML");
    return view_devices(token, chat_id, null);
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
        push(keyboard, [{ text: "📊 Полный статус AI", callback_data: "/ai_status_full" }]);
    } else {
        push(keyboard, [{ text: "▶️ Запустить Watchdog", callback_data: "/wd_start" }]);
    }
    push(keyboard, [{ text: "⬅️ Назад", callback_data: "/menu" }]);
    
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function exec_ai_heal(token, chat_id, msg_id) {
    send_message(token, chat_id, "🤖 <b>ИИ-Автомеханик выполняет диагностику и самолечение...</b>", "HTML");

    command_status(command_from_args(["/usr/bin/tachyon", "ai_heal"]));

    let status_data = fs.readfile("/tmp/tachyon_ai_status.json");
    let text = "🤖 <b>[ИИ-Автомеханик Tachyon]</b>\n\n";
    if (status_data) {
        try {
            let st = json(status_data);
            if (st.last_incident) {
                text += "⚠️ <b>Устранён инцидент:</b> " + escape_html(st.last_incident.description || "") + "\n";
                text += "🔧 <b>Авто-решение:</b> " + escape_html(st.last_incident.resolution || "") + "\n\n";
                text += "Все системы приведены в штатную норму! 🟢";
            } else {
                text += "🟢 Все сетевые службы, DNS, nftables и память работают идеально.";
            }
        } catch(e) {
            text += "🟢 Диагностика завершена успешно.";
        }
    } else {
        text += "🟢 Диагностика завершена.";
    }

    let keyboard = [[{ text: "⬅️ В меню", callback_data: "/menu" }]];
    send_message(token, chat_id, text, "HTML", keyboard);
}

function exec_ai_status_full(token, chat_id, msg_id) {
    send_message(token, chat_id, "🔍 <b>Сбор полного AI Watchdog статуса...</b>", "HTML");
    let res = command_capture(command_from_args([ "/usr/bin/tachyon", "ai_status_full" ]));
    let data = res ? (res.output || "Нет данных.") : "Ошибка получения статуса.";
    if (length(data) > 3500) data = substr(data, 0, 3500) + "\n... (данные сокращены)";
    let text = "🤖 <b>AI Watchdog — Полный статус:</b>\n\n<pre>" + escape_html(data) + "</pre>";
    let keyboard = [[{ text: "⬅️ Назад", callback_data: "/watchdog" }]];
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function view_qos(token, chat_id, msg_id) {
    let c = uci_core.cursor(); c.load(CONFIG_NAME);
    let cfg = c.get_all(CONFIG_NAME, "settings") || {};
    let enabled = cfg.qos_priority_engine != "0";
    
    let text = "🎮 <b>Игровой & Голосовой QoS Ускоритель</b>\n\n" +
               "Статус: <code>" + (enabled ? "🟢 Включен (DSCP EF + AF41 Priority)" : "⚪ Выключен") + "</code>\n\n" +
               "<b>Приоритетные правила:</b>\n" +
               "├ 🎙️ <b>Golos/Discord/RTC:</b> UDP 5000-5020, 3478, 50000-65535 ➔ <code>DSCP EF (0x2e)</code>\n" +
               "├ 🎮 <b>Games (Steam/CS/Dota/Apex/PUBG/Roblox):</b> UDP 27000-27050, 3074 ➔ <code>DSCP AF41 (0x22)</code>\n" +
               "└ ⚡ <b>TCP ACK Acceleration:</b> малые ACK пакеты ➔ <code>High Priority</code>";

    let keyboard = [
        [{ text: (enabled ? "⏹️ Отключить QoS" : "⚡ Включить QoS"), callback_data: "/qos_toggle" }],
        [{ text: "⬅️ Назад", callback_data: "/menu" }]
    ];
    if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    else send_message(token, chat_id, text, "HTML", keyboard);
}

function handle_qos_toggle(token, chat_id, msg_id) {
    let c = uci_core.cursor(); c.load(CONFIG_NAME);
    let cfg = c.get_all(CONFIG_NAME, "settings") || {};
    let new_val = (cfg.qos_priority_engine == "0") ? "1" : "0";
    c.set(CONFIG_NAME, "settings", "qos_priority_engine", new_val);
    c.commit(CONFIG_NAME);
    system(common.background_command("/usr/bin/tachyon reload_firewall"));
    view_qos(token, chat_id, msg_id);
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
    return allowed[name] ? true : false;
}

// ─── Dispatcher ──────────────────────────────────────────────────────────────

function dispatch_command(token, chat_id, text, msg_id) {
    let cmd = trim(as_string(text));

    // Resolve tokenized callbacks produced by cb_data() for oversized payloads
    if (match(cmd, /^\/cb /)) {
        let cb_tok = trim(substr(cmd, 4));
        let full = cb_map_get(cb_tok);
        if (full == null || full == "") {
            return send_message(token, chat_id,
                "⚠️ Кнопка устарела — откройте список заново.", "HTML",
                [[{ text: "⬅️ Меню", callback_data: "/menu" }]]);
        }
        cmd = trim(full);
    }

    let state = get_tg_state(chat_id);
    
    if (cmd == "/noop") return;
    if (cmd == "/start" || cmd == "/menu") return view_menu(token, chat_id, msg_id);
    if (cmd == "/status") return view_status(token, chat_id, msg_id);
    if (cmd == "/runtime") return view_runtime(token, chat_id, msg_id);
    if (cmd == "/heal" || cmd == "/ai_heal") return exec_ai_heal(token, chat_id, msg_id);
    if (cmd == "/qos") return view_qos(token, chat_id, msg_id);
    if (cmd == "/qos_toggle") return handle_qos_toggle(token, chat_id, msg_id);

    if (cmd == "/speed") return exec_speedtest(token, chat_id, msg_id);
    if (cmd == "/ping") return view_ping(token, chat_id, msg_id);
    if (cmd == "/test") return view_quick_test(token, chat_id, msg_id);
    if (cmd == "/info") return view_system_info(token, chat_id, msg_id);
    if (cmd == "/help") return view_help(token, chat_id, msg_id);

    if (match(cmd, /^\/logs /)) {
        let parts = split(trim(substr(cmd, 6)), " ");
        return view_logs(token, chat_id, msg_id, parts[0] || "all", parts[1] || "30");
    }
    if (cmd == "/logs") return view_logs(token, chat_id, msg_id);

    if (match(cmd, /^\/connections /)) {
        let page = trim(substr(cmd, 13));
        return view_connections(token, chat_id, msg_id, page);
    }
    if (cmd == "/connections") return view_connections(token, chat_id, msg_id);

    if (cmd == "/test_rule") return view_test_rule(token, chat_id, msg_id);
    if (cmd == "/export_config") return exec_export_config(token, chat_id, msg_id);
    if (cmd == "/qh") return view_quiet_hours(token, chat_id, msg_id);
    if (cmd == "/qh_toggle") return handle_qh_toggle(token, chat_id, msg_id);
    if (cmd == "/qh_start" || cmd == "/qh_end") {
        let which = (cmd == "/qh_start") ? "start" : "end";
        set_tg_state(chat_id, { action: "qh_hour", which: which });
        return send_message(token, chat_id,
            "⏰ Введите час " + (which == "start" ? "начала" : "окончания") +
            " тихих часов (0–23):\n\n<i>Отправьте /cancel для отмены</i>", "HTML");
    }
    
    if (cmd == "/outbounds") return view_outbounds(token, chat_id, msg_id);
    if (match(cmd, /^\/outbounds /)) {
        let grp = trim(substr(cmd, 11));
        return view_outbounds(token, chat_id, msg_id, grp);
    }
    
    if (cmd == "/sections") return view_sections(token, chat_id, msg_id);
    if (cmd == "/devices") return view_devices(token, chat_id, msg_id);
    if (match(cmd, /^\/toggle_mac /)) {
        let mac = trim(substr(cmd, 12));
        return handle_toggle_mac(token, chat_id, mac);
    }
    if (cmd == "/watchdog") return view_watchdog(token, chat_id, msg_id);
    if (cmd == "/doctor") return exec_doctor(token, chat_id);
    if (cmd == "/ai_status_full") return exec_ai_status_full(token, chat_id, msg_id);
    if (cmd == "/restart") return exec_restart(token, chat_id);
    if (cmd == "/confirm_restart") {
        if (msg_id) return apply_confirmed_restart(token, chat_id, msg_id);
        return exec_restart(token, chat_id);
    }
    if (cmd == "/backup") return exec_backup(token, chat_id);
    if (cmd == "/support_bundle") return exec_support_bundle(token, chat_id);
    if (cmd == "/close_connections") return exec_close_connections(token, chat_id);
    if (cmd == "/instances") return view_instances(token, chat_id, msg_id);
    if (cmd == "/check_updates") return exec_check_updates(token, chat_id, msg_id);
    
    if (match(cmd, /^\/update_component /)) {
        let comp = trim(substr(cmd, 17));
        if (!valid_updatable_component(comp)) {
            send_message(token, chat_id, "❌ <b>Неизвестный компонент:</b> <code>" + escape_html(comp) + "</code>", "HTML", [[{text:"⬅️ Меню", callback_data:"/menu"}]]);
            return;
        }
        if (msg_id) edit_message(token, chat_id, msg_id, "⏳ <b>Запуск обновления " + escape_html(comp) + "...</b>\nПроцесс запущен в фоне. Зайдите позже.", "HTML", [[{text:"⬅️ Меню", callback_data:"/menu"}]]);
        else send_message(token, chat_id, "⏳ <b>Запуск обновления " + escape_html(comp) + "...</b>\nПроцесс запущен в фоне. Зайдите позже.", "HTML", [[{text:"⬅️ Меню", callback_data:"/menu"}]]);
        command_status(command_from_args(["/usr/bin/tachyon", "component_action_async", comp, "install"]));
        return;
    }
    
    if (match(cmd, /^\/admin_add /)) {
        let fwd_id = trim(substr(cmd, 11));
        if (!match(fwd_id, /^-?[0-9]+$/)) {
            send_message(token, chat_id, "❌ Неверный Chat ID.", "HTML");
            return;
        }
        let c = uci_core.cursor(); c.load(CONFIG_NAME);
        let s = c.get_all(CONFIG_NAME, "telegram");
        let current_admins = option(s, "admin_ids", "");
        let admins_list = split(current_admins, /,/);
        let found = false;
        for (let a in admins_list) if (trim(a) == fwd_id) found = true;
        
        if (!found) {
            let new_admins = current_admins != "" ? current_admins + "," + fwd_id : fwd_id;
            c.set(CONFIG_NAME, "telegram", "admin_ids", new_admins);
            c.commit(CONFIG_NAME);
            if (msg_id) edit_message(token, chat_id, msg_id, "✅ Пользователь `" + fwd_id + "` добавлен в список администраторов.", "Markdown", [[{text:"⬅️ Меню", callback_data:"/menu"}]]);
            else send_message(token, chat_id, "✅ Пользователь `" + fwd_id + "` добавлен в список администраторов.", "Markdown", [[{text:"⬅️ Меню", callback_data:"/menu"}]]);
        } else {
            if (msg_id) edit_message(token, chat_id, msg_id, "ℹ️ Пользователь `" + fwd_id + "` уже является администратором.", "Markdown", [[{text:"⬅️ Меню", callback_data:"/menu"}]]);
        }
        return;
    }
    
    if (cmd == "/wd_start") {
        command_status(command_from_args(["/usr/bin/tachyon", "watchdog_start"]));
        return view_watchdog(token, chat_id, msg_id);
    }
    if (cmd == "/wd_stop") {
        command_status(command_from_args(["/usr/bin/tachyon", "watchdog_stop"]));
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
        let s = c.get_all(CONFIG_NAME, sec);
        if (!s) {
            send_message(token, chat_id, "❌ Секция <code>" + sec + "</code> не найдена.", "HTML");
            return view_sections(token, chat_id, null);
        }
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

    
    if (cmd == "/settings") return view_settings_menu(token, chat_id, msg_id);
    if (match(cmd, /^\/set_list /)) {
        let stype = trim(substr(cmd, 10));
        return view_set_list(token, chat_id, msg_id, stype);
    }
    if (match(cmd, /^\/set_cat /)) {
        let parts = split(trim(substr(cmd, 9)), " ");
        if (length(parts) >= 2) return view_set_cat(token, chat_id, msg_id, parts[0], parts[1], parts[2]);
    }
    if (match(cmd, /^\/set_tog /)) {
        let parts = split(trim(substr(cmd, 9)), " ");
        if (length(parts) >= 4) return handle_set_tog(token, chat_id, msg_id, parts[0], parts[1], parts[2], parts[3]);
    }
    if (match(cmd, /^\/set_arr /)) {
        let parts = split(trim(substr(cmd, 9)), " ");
        if (length(parts) >= 3) return view_set_arr(token, chat_id, msg_id, parts[0], parts[1], parts[2]);
    }
    if (match(cmd, /^\/set_arr_del /)) {
        let parts = split(trim(substr(cmd, 13)), " ");
        if (length(parts) >= 4) {
            let stype = parts[0]; let sname = parts[1]; let key = parts[2]; let val = join(" ", slice(parts, 3));
            let c = uci_core.cursor(); c.load(CONFIG_NAME);
            let s = c.get_all(CONFIG_NAME, sname);
            let current = common.list_option(s, key);
            let n = [];
            for (let x in current) if (x != val) push(n, x);
            c.set(CONFIG_NAME, sname, key, n); c.commit(CONFIG_NAME);
            return view_set_arr(token, chat_id, msg_id, stype, sname, key);
        }
    }
    if (match(cmd, /^\/set_arr_clr /)) {
        let parts = split(trim(substr(cmd, 13)), " ");
        if (length(parts) >= 3) {
            let c = uci_core.cursor(); c.load(CONFIG_NAME);
            c.delete(CONFIG_NAME, parts[1], parts[2]); c.commit(CONFIG_NAME);
            return view_set_arr(token, chat_id, msg_id, parts[0], parts[1], parts[2]);
        }
    }
    if (match(cmd, /^\/set_str /)) {
        let parts = split(trim(substr(cmd, 9)), " ");
        if (length(parts) >= 3) {
            set_tg_state(chat_id, { action: "set_str", stype: parts[0], sname: parts[1], key: parts[2] });
            return send_message(token, chat_id, "📝 Введите новое значение для <code>" + parts[2] + "</code>:\n\n<i>Отправьте /cancel для отмены</i>", "HTML");
        }
    }
    if (match(cmd, /^\/set_arr_add /)) {
        let parts = split(trim(substr(cmd, 13)), " ");
        if (length(parts) >= 3) {
            set_tg_state(chat_id, { action: "set_arr_add", stype: parts[0], sname: parts[1], key: parts[2] });
            return send_message(token, chat_id, "➕ Отправьте элементы для добавления в список (через пробел или с новой строки):\n\n<i>Отправьте /cancel для отмены</i>", "HTML");
        }
    }

    if (cmd == "/dns_presets" || cmd == "/dns_servers") {
        let c = uci_core.cursor(); c.load(CONFIG_NAME);
        let s = c.get_all(CONFIG_NAME, "settings");
        let dns_type = option(s, "dns_type", "doh");
        let text = dns_presets.format_presets_list(dns_type);
        let presets = dns_presets.get_presets(dns_type);
        let keyboard = [];
        for (let i = 0; i < length(presets); i++) {
            let p = presets[i];
            push(keyboard, [{ text: p.country + " " + p.name, callback_data: "/dns_apply " + as_string(i) }]);
        }
        push(keyboard, [{ text: "📋 Все протоколы", callback_data: "/dns_protocols" }]);
        push(keyboard, [{ text: "⬅️ Назад", callback_data: "/settings" }]);
        if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
        else send_message(token, chat_id, text, "HTML", keyboard);
        return;
    }
    if (match(cmd, /^\/dns_apply /)) {
        let idx = int(trim(substr(cmd, 11)));
        let c = uci_core.cursor(); c.load(CONFIG_NAME);
        let s = c.get_all(CONFIG_NAME, "settings");
        let dns_type = option(s, "dns_type", "doh");
        let presets = dns_presets.get_presets(dns_type);
        if (idx >= 0 && idx < length(presets)) {
            let preset = presets[idx];
            let servers = dns_presets.get_preset_servers(preset);
            c.delete(CONFIG_NAME, "settings", "dns_server");
            for (let srv in servers) c.add_list(CONFIG_NAME, "settings", "dns_server", srv);
            c.commit(CONFIG_NAME);
            send_message(token, chat_id, "✅ <b>DNS серверы установлены:</b>\n" + dns_presets.format_preset(preset, idx) + "\n\nТип: <code>" + dns_type + "</code>\n\n⚠️ Выполните перезапуск для применения.", "HTML", [[{text: "🔄 Перезапустить", callback_data: "/confirm_restart"}, {text: "⬅️ Назад", callback_data: "/dns_presets"}]]);
        }
        return;
    }
    if (cmd == "/bootstrap_presets") {
        let text = dns_presets.format_bootstrap_presets_list();
        let presets = dns_presets.get_bootstrap_presets();
        let keyboard = [];
        for (let i = 0; i < length(presets); i++) {
            let p = presets[i];
            push(keyboard, [{ text: p.country + " " + p.name, callback_data: "/bootstrap_apply " + as_string(i) }]);
        }
        push(keyboard, [{ text: "⬅️ Назад", callback_data: "/settings" }]);
        if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
        else send_message(token, chat_id, text, "HTML", keyboard);
        return;
    }
    if (match(cmd, /^\/bootstrap_apply /)) {
        let idx = int(trim(substr(cmd, 17)));
        let presets = dns_presets.get_bootstrap_presets();
        if (idx >= 0 && idx < length(presets)) {
            let preset = presets[idx];
            let servers = dns_presets.get_preset_servers(preset);
            let c = uci_core.cursor(); c.load(CONFIG_NAME);
            c.delete(CONFIG_NAME, "settings", "bootstrap_dns_server");
            for (let srv in servers) c.add_list(CONFIG_NAME, "settings", "bootstrap_dns_server", srv);
            c.commit(CONFIG_NAME);
            send_message(token, chat_id, "✅ <b>Bootstrap DNS серверы установлены:</b>\n" + dns_presets.format_preset(preset, idx) + "\n\n⚠️ Выполните перезапуск для применения.", "HTML", [[{text: "🔄 Перезапустить", callback_data: "/confirm_restart"}, {text: "⬅️ Назад", callback_data: "/bootstrap_presets"}]]);
        }
        return;
    }
    if (cmd == "/dns_protocols") {
        let text = dns_presets.format_protocol_info();
        let keyboard = [[{ text: "⬅️ Назад", callback_data: "/dns_presets" }]];
        if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
        else send_message(token, chat_id, text, "HTML", keyboard);
        return;
    }

    if (match(cmd, /^\/sw /)) {
        let rest = trim(substr(cmd, 4));
        let space_idx = index(rest, " ");
        if (space_idx > 0) {
            let grp = substr(rest, 0, space_idx);
            let srv = substr(rest, space_idx + 1);
            return handle_switch(token, chat_id, msg_id, grp, srv);
        }
    }
    
    // Default / Help
    if (!msg_id) {
        view_menu(token, chat_id, null);
    }
}

function process_updates(token, admin_ids) {
    let offset = int(trim(fs.readfile(OFFSET_FILE) || "0"));
    let res = tg_request(token, "getUpdates", { offset: offset, timeout: 20 });
    
    if (!res || !res.ok || !res.result) return false;
    if (length(res.result) == 0) return true;
    
    for (let upd in res.result) {
        let update_id = upd.update_id;
        if (update_id >= offset) {
            offset = update_id + 1;
        }

        try {
        let cb = upd.callback_query;
        if (cb) {
            let chat_id = cb.message ? cb.message.chat.id : (cb.from ? cb.from.id : null);
            if (!chat_id) continue;
            if (!is_admin(chat_id, admin_ids)) {
                tg_request(token, "answerCallbackQuery", { callback_query_id: cb.id, text: "Access Denied" });
                continue;
            }
            try {
                dispatch_command(token, chat_id, cb.data, cb.message ? cb.message.message_id : null);
            } catch (e) {
                send_message(token, chat_id, "❌ Ошибка выполнения команды: " + escape_html(as_string(e)), "HTML");
            }
            tg_request(token, "answerCallbackQuery", { callback_query_id: cb.id });
            continue;
        }

        let msg = upd.message;
        if (msg) {
            let chat_id = msg.chat ? msg.chat.id : null;
            if (!chat_id) continue;

            if (!is_admin(chat_id, admin_ids)) {
                if (msg.text || msg.document) {
                    send_message(token, chat_id, "❌ Доступ запрещен. Ваш Chat ID: `" + chat_id + "`", "Markdown");
                }
                continue;
            }

            if (msg.document) {
                let doc = msg.document;
                if (match(doc.file_name || "", /\.tar\.gz$/)) {
                    send_message(token, chat_id, "⏳ <b>Скачиваю бэкап...</b>", "HTML");
                    let file_url = get_file_url(token, doc.file_id);
                    if (file_url) {
                        let dl_path = "/tmp/restore_" + doc.file_id + ".tar.gz";
                        let proxy = get_proxy_args();
                        let dl_args = [ "curl", "-s", "-o", dl_path ];
                        for (let p in proxy) push(dl_args, p);
                        push(dl_args, file_url);
                        command_status(command_from_args(dl_args));
                        if (fs.stat(dl_path)) {
                            apply_backup_restore(token, chat_id, dl_path);
                        } else {
                            send_message(token, chat_id, "❌ <b>Ошибка загрузки файла.</b>", "HTML");
                        }
                    } else {
                        send_message(token, chat_id, "❌ <b>Ошибка получения URL файла.</b>", "HTML");
                    }
                } else {
                    send_message(token, chat_id, "ℹ️ Пожалуйста, отправьте бэкап в формате `.tar.gz`.", "Markdown");
                }
                continue;
            }

            if (msg.forward_from) {
                let fwd_id = msg.forward_from.id;
                let text = "👤 Вы переслали сообщение от пользователя `" + fwd_id + "`.\nДобавить его в список администраторов бота?";
                let keyboard = [[{text: "✅ Добавить", callback_data: "/admin_add " + fwd_id}]];
                send_message(token, chat_id, text, "Markdown", keyboard);
                continue;
            }

            if (msg.text) {
                if (match(msg.text, /^> /)) {
                    let exec_cmd = trim(substr(msg.text, 2));
                    send_message(token, chat_id, "⏳ Выполняю из разрешённого набора (whitelist):\n<code>" + escape_html(exec_cmd) + "</code>", "HTML");
                    let out = safe_execute(exec_cmd);
                    let result_text = "<b>Выполнено (код " + out.status + "):</b>\n<pre>" + escape_html(out.output || "Нет вывода") + "</pre>";
                    if (length(result_text) > 4000) result_text = substr(result_text, 0, 4000) + "...</pre>";
                    send_message(token, chat_id, result_text, "HTML");
                    continue;
                }

                if (msg.text == "/cancel") {
                    set_tg_state(chat_id, null);
                    send_message(token, chat_id, "❌ Действие отменено.", "HTML", [[{text:"⬅️ Меню", callback_data:"/menu"}]]);
                    continue;
                }
            }

            let state = get_tg_state(chat_id);
            if (state) {
                if (msg.text && substr(msg.text, 0, 1) == "/") {
                    set_tg_state(chat_id, null);
                    dispatch_command(token, chat_id, msg.text, null);
                    continue;
                }

                if (!msg.text) {
                    send_message(token, chat_id, "⚠️ Ожидается текстовое сообщение. Попробуйте ещё раз или /cancel.", "HTML");
                    continue;
                }

                let c = uci_core.cursor();
                c.load(CONFIG_NAME);

                if (state.action == "set_str") {
                    let val = trim(msg.text);
                    c.set(CONFIG_NAME, state.sname, state.key, val);
                    c.commit(CONFIG_NAME);
                    set_tg_state(chat_id, null);
                    send_message(token, chat_id, "✅ Значение <code>" + state.key + "</code> сохранено.", "HTML");
                    view_set_cat(token, chat_id, null, state.stype, state.sname, 0);
                }
                else if (state.action == "set_arr_add") {
                    let items = split(trim(msg.text), /[ \t\r\n,;]+/);
                    let valid = [];
                    for (let x in items) if (trim(x) != "") push(valid, trim(x));
                    if (length(valid) > 0) {
                        let cur = common.list_option(c.get_all(CONFIG_NAME, state.sname), state.key);
                        for (let x in valid) push(cur, x);
                        c.set(CONFIG_NAME, state.sname, state.key, cur);
                        c.commit(CONFIG_NAME);
                        set_tg_state(chat_id, null);
                        send_message(token, chat_id, "✅ Добавлено элементов: " + length(valid));
                    } else {
                        set_tg_state(chat_id, null);
                    }
                    view_set_arr(token, chat_id, null, state.stype, state.sname, state.key);
                }
                else if (state.action == "sec_create") {
                    let new_sec = trim(msg.text);
                    if (match(new_sec, /^[a-zA-Z0-9_]+$/)) {
                        c.set(CONFIG_NAME, new_sec, "section");
                        c.set(CONFIG_NAME, new_sec, "action", "proxy");
                        c.set(CONFIG_NAME, new_sec, "enabled", "1");
                        c.set(CONFIG_NAME, new_sec, "label", new_sec);
                        c.commit(CONFIG_NAME);
                        set_tg_state(chat_id, null);
                        send_message(token, chat_id, "✅ Секция создана!");
                        view_section_editor(token, chat_id, null, new_sec);
                    } else {
                        set_tg_state(chat_id, state);
                        send_message(token, chat_id, "❌ Неверное имя. Разрешены только буквы, цифры и подчеркивания.");
                    }
                }
                else if (state.action == "sec_rename") {
                    let new_label = trim(msg.text);
                    c.set(CONFIG_NAME, state.sec, "label", new_label);
                    c.commit(CONFIG_NAME);
                    set_tg_state(chat_id, null);
                    send_message(token, chat_id, "✅ Имя изменено.");
                    view_section_editor(token, chat_id, null, state.sec);
                }
                else if (state.action == "sec_target") {
                    let new_target = trim(msg.text);
                    c.set(CONFIG_NAME, state.sec, "target", new_target);
                    c.commit(CONFIG_NAME);
                    set_tg_state(chat_id, null);
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
                        set_tg_state(chat_id, null);
                        send_message(token, chat_id, "✅ Добавлено " + length(valid_items) + " элементов.");
                    } else {
                        set_tg_state(chat_id, null);
                        send_message(token, chat_id, "❌ Ничего не добавлено.");
                    }
                    view_sec_list(token, chat_id, null, state.sec, state.list);
                }
                else if (state.action == "test_rule") {
                    view_test_rule(token, chat_id, null, trim(msg.text));
                }
                else if (state.action == "qh_hour") {
                    let val = trim(msg.text);
                    if (!match(val, /^([0-9]|1[0-9]|2[0-3])$/)) {
                        set_tg_state(chat_id, state);
                        send_message(token, chat_id, "❌ Введите целое число от 0 до 23.", "HTML");
                    } else {
                        let key = (state.which == "start") ? "quiet_hours_start" : "quiet_hours_end";
                        c.set(CONFIG_NAME, "telegram", key, val);
                        c.commit(CONFIG_NAME);
                        set_tg_state(chat_id, null);
                        send_message(token, chat_id, "✅ Сохранено.", "HTML");
                        view_quiet_hours(token, chat_id, null);
                    }
                }
                continue;
            }

            dispatch_command(token, chat_id, msg.text, null);
        }
        } catch (e) {
            command_success_from_args(["logger", "-t", "tachyon", "[err] Telegram update " + update_id + " failed: " + as_string(e)]);
        }
    }
    fs.writefile(OFFSET_FILE, as_string(offset));
    return true;
}

// ─── Entry Point ─────────────────────────────────────────────────────────────

function send_daily_digest(token, admin_ids) {
    let text = "📊 <b>Утренний дайджест Tachyon</b>\n\n";
    let uptime_out = command_output_from_args(["uptime"]);
    let m = match(uptime_out, /up ([^,]+)/);
    let up = m ? m[1] : "неизвестно";
    text += "⏱ Аптайм ОС: " + up + "\n";
    
    let res = command_capture(command_from_args(["curl", "-s", "http://127.0.0.1:4534/traffic"]));
    if (res && res.status == 0 && res.output) {
        try {
            let tr = json(res.output);
            text += "🔻 Текущий RX: " + format_bytes(tr.down) + "/s\n";
            text += "🔺 Текущий TX: " + format_bytes(tr.up) + "/s\n";
        }
        catch (e) {
            // Traffic counters are decoration on a status message; a clash API
            // that answers with something unparseable just omits two lines.
        }
    }
    
    let admins = split(admin_ids, /,/);
    for (let admin in admins) {
        let chat_id = trim(admin);
        if (chat_id != "") send_message(token, chat_id, text, "HTML", null);
    }
}

function check_notified_updates(token, admin_ids) {
    let out = command_output_from_args(["/usr/bin/tachyon", "component_update_check_cache"]);
    if (!out || out == "") return;
    try {
        let data = json(out);
        let notified_file = "/tmp/tg_notified_updates.json";
        let notified = {};
        let ndata = fs.readfile(notified_file);
        // A corrupt notified-file re-announces updates already announced once.
        if (ndata) { try { notified = json(ndata); } catch(e){} }
        
        let changed = false;
        let results = data.results || [];
        for (let comp in results) {
            let name = comp.component || "";
            if (name == "") continue;
            if (comp.success !== true) continue;
            if (comp.status == "outdated" || comp.status == "outdated_same_release") {
                let latest = comp.latest_version;
                // Keyed by version *and* build: a rebuild under an existing tag
                // leaves the version untouched, so a version-only key would
                // suppress its notification forever. Entries written by older
                // builds hold a bare version and simply miss once.
                let identity = build_identity_key(comp);
                let key = as_string(latest) + (identity != "" ? ":" + identity : "");
                if (notified[name] != key) {
                    let title = (name == "sing_box") ? "sing-box" : name;
                    let cur = comp.current_version || "?";
                    let msg;
                    if (comp.status == "outdated_same_release") {
                        let transition = build_transition(comp);
                        msg = "📦 <b>Новая сборка текущего релиза!</b>\n" + title + ": <code>" + escape_html(cur) + "</code>" +
                            (transition != "" ? "\nСборка: " + transition : "");
                    } else {
                        msg = "📦 <b>Доступно обновление компонента!</b>\n" + title + ": <code>" + escape_html(cur) + "</code> ➡️ <code>" + escape_html(as_string(latest)) + "</code>";
                    }
                    let kb = [[{text: "🔄 Обновить " + title, callback_data: "/update_component " + name}]];

                    let admins = split(admin_ids, /,/);
                    for (let admin in admins) {
                        let cid = trim(admin);
                        if (cid != "") send_message(token, cid, msg, "HTML", kb);
                    }
                    notified[name] = key;
                    changed = true;
                }
            }
        }
        if (changed) fs.writefile(notified_file, sprintf("%J", notified));
    }
    catch (e) {
        // The update-check cache is written by another process and may be
        // half-written when read. Skipping this round costs one notification
        // cycle; the next worker pass reads it again.
    }
}

function worker() {
    let cfg = settings();
    if (cfg.enabled != "1" || !cfg.bot_token) return 0;

    let commands = [
        { command: "menu",      description: "Главное меню" },
        { command: "status",    description: "Статус системы" },
        { command: "runtime",   description: "Статистика трафика" },
        { command: "outbounds", description: "Прокси серверы" },
        { command: "sections",  description: "Секции маршрутизации" },
        { command: "instances", description: "Live серверы" },
        { command: "speed",     description: "Тест скорости" },
        { command: "ping",      description: "Задержка до серверов" },
        { command: "test",      description: "Быстрая диагностика" },
        { command: "logs",      description: "Просмотр логов" },
        { command: "info",      description: "Информация о системе" },
        { command: "connections", description: "Активные подключения" },
        { command: "test_rule", description: "Проверка правила" },
        { command: "help",      description: "Справка" },
        { command: "check_updates", description: "Проверить обновления" },
        { command: "close_connections", description: "Закрыть все соединения" },
        { command: "doctor",    description: "Диагностика" },
        { command: "restart",   description: "Перезапуск служб Tachyon" }
    ];
    tg_request(cfg.bot_token, "setMyCommands", { commands: commands });

    // Clean up leftover payload temp-files from previous runs that were
    // interrupted (e.g. killed during a 20-second getUpdates long-poll).
    let tmp = fs.opendir("/tmp");
    if (tmp) {
        let entry;
        while ((entry = tmp.read()) != null) {
            if (index(entry, "tg_payload_") == 0 && substr(entry, -5) == ".json")
                try { fs.unlink("/tmp/" + entry); } catch(e) {}
        }
        tmp.close();
    }

    let poll_interval = int(cfg.poll_interval || "5");
    if (poll_interval < 1) poll_interval = 1;

    let last_report_day = -1;
    let last_update_check = 0;
    let consecutive_failures = 0;

    while (true) {
        try {
            cfg = settings();
            if (cfg.enabled != "1") break;
            let res = process_updates(cfg.bot_token, cfg.admin_ids);
            
            if (res === false) {
                consecutive_failures++;
                let backoff = poll_interval * (1 << min(consecutive_failures - 1, 4));
                if (backoff > 300) backoff = 300;
                command_success_from_args(["logger", "-t", "tachyon-telegram", "[warn] API failure " + as_string(consecutive_failures) + ", backing off " + as_string(backoff) + "s"]);
                sleep(backoff * 1000);
                continue;
            }
            consecutive_failures = 0;

            let now = time();
            // localtime() yields { sec, min, hour, mday, mon, year, ... }.
            // clock() returns [seconds, microseconds] and has no calendar fields.
            let tm = localtime(now);
            let daily_hour = int(cfg.daily_report_hour || "8");

            if (cfg.daily_report_enabled == "1" && tm && tm.hour == daily_hour && tm.mday != last_report_day) {
                last_report_day = tm.mday;
                send_daily_digest(cfg.bot_token, cfg.admin_ids);
            }
            
            if (now - last_update_check > 3600) {
                check_notified_updates(cfg.bot_token, cfg.admin_ids);
                last_update_check = now;
            }
        } catch (e) {
            consecutive_failures++;
            command_success_from_args(["logger", "-t", "tachyon-telegram", "[err] Worker loop error: " + as_string(e)]);
        }
        
        sleep(poll_interval * 1000);
    }
    return 0;
}

function stop_runtime() {
    let pid = trim(fs.readfile(PID_FILE) || "");
    if (pid != "" && match(pid, /^[0-9]+$/) != null && command_success_from_args([ "kill", "-0", pid ])) {
        command_success_from_args([ "kill", pid ]);
        let wait_limit = 30;
        while (wait_limit > 0 && command_success_from_args([ "kill", "-0", pid ])) {
            sleep(100);
            wait_limit--;
        }
        if (command_success_from_args([ "kill", "-0", pid ])) {
            command_success_from_args([ "kill", "-9", pid ]);
        }
    }
    // Absent file already satisfies the caller; fs.unlink throws on ENOENT.
    try { fs.unlink(PID_FILE); } catch(e) {}
    return 0;
}

function start_runtime() {
    let cfg = settings();
    stop_runtime();
    if (cfg.enabled != "1" || !cfg.bot_token) return 0;
    
    let command = common.background_command_with_pid(
        command_from_args([ "ucode", "-L", LIB_DIR, LIB_DIR + "/service/telegram.uc", "worker" ]),
        ">/var/log/tachyon_telegram.log", ">" + shell_quote(PID_FILE));
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

function in_quiet_hours(cfg) {
    if (cfg.quiet_hours_enabled != "1") return false;
    let start = int(cfg.quiet_hours_start || "23");
    let end = int(cfg.quiet_hours_end || "7");
    if (start == end) return false;
    let tm = localtime(time());
    if (!tm) return false;
    let hr = int(tm.hour);
    if (start <= end) {
        return hr >= start && hr < end;
    } else {
        return hr >= start || hr < end;
    }
}

function send_api(message) {
    let cfg = settings();
    if (cfg.enabled != "1" || !cfg.bot_token || !cfg.admin_ids) return 1;
    
    // Check if this is a non-critical watchdog message and we are in quiet hours
    let is_critical = (index(message, "Упал") >= 0 || index(message, "Ошибка") >= 0);
    if (!is_critical && in_quiet_hours(cfg)) return 0;
    
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
else if (mode == "send") {
    // Collect remaining args after "send" as the message text
    let msg_parts = [];
    for (let i = 2; i < length(ARGV); i++)
        push(msg_parts, ARGV[i]);
    let message = join(" ", msg_parts);
    if (message == "") { warn("No message text\n"); exit(1); }
    exit(send_api(message));
}
else {
    warn("Usage: service/telegram.uc <start-runtime|stop-runtime|worker|status|send ...> ...\n");
    exit(1);
}
