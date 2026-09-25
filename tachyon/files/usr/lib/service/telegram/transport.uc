#!/usr/bin/env ucode
//
// Telegram bot transport: HTTP client, proxy routing, fallback, heartbeat,
// token callback caching and low-level Telegram Bot API requests.
// Extracted from service/telegram.uc (Branch 7 god-module refactor).
//

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let helpers = require("core.helpers");
let api = require("service.api");
let i18n = require("service.i18n");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const CB_MAP_FILE = "/tmp/tg_cb_map.json";
const CB_MAP_MAX = 300;
const HEARTBEAT_FILE = "/var/run/tachyon_telegram.heartbeat";
const LOG_FILE = "/var/log/tachyon_telegram.log";
const LOG_MAX_BYTES = 524288;
const LOG_KEEP_BYTES = 102400;
const MIXED_PORT_PROBE_TTL = 30;

let as_string = common.as_string;
let object_or_empty = common.object_or_empty;
let command_from_args = common.command_from_args;
let command_capture = common.command_capture;
let command_output_from_args = common.command_output_from_args;
let command_success_from_args = common.command_success_from_args;
let write_text_file = helpers.write_text_file;

let cb_map_cache = null;
let mixed_port_alive_cached = null;
let mixed_port_checked_at = 0;

function get_t() {
    let cfg = object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
    return i18n.bind(cfg.language || "en");
}

// ─── Callback Data Helpers ────────────────────────────────────────────────────

function cb_map_load() {
    if (cb_map_cache != null)
        return cb_map_cache;
    let data = fs.readfile(CB_MAP_FILE);
    if (data) {
        try {
            let obj = json(data);
            if (type(obj) == "object") {
                cb_map_cache = obj;
                return cb_map_cache;
            }
        }
        catch (e) {
            command_success_from_args([ "logger", "-t", "tachyon-telegram",
                "[warn] callback map is unparseable, starting from empty: " + as_string(e) ]);
        }
    }
    cb_map_cache = {};
    return cb_map_cache;
}

function cb_map_store(token, value) {
    let map = cb_map_load();
    if (map[token] == value)
        return;
    let ks = keys(map);
    if (length(ks) >= CB_MAP_MAX) {
        let pruned = {};
        for (let i = int(length(ks) / 2); i < length(ks); i++)
            pruned[ks[i]] = map[ks[i]];
        map = pruned;
        cb_map_cache = map;
    }
    map[token] = value;
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
    let token = sprintf("%08x%02x", h & 0xFFFFFFFF, length(s) & 0xFF);
    cb_map_store(token, s);
    return "/cb " + token;
}

// ─── Settings & Config ────────────────────────────────────────────────────────

function settings() {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
}

function get_mixed_proxy_info() {
    let settings_data = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
    let config_path = trim(as_string(settings_data.config_path || "")) || "/etc/sing-box/config.json";
    let data = fs.readfile(config_path);
    if (data == null) return null;
    let parsed;
    try { parsed = json(data); } catch (e) { return null; }
    if (parsed == null || parsed.inbounds == null) return null;

    for (let inbound in parsed.inbounds) {
        if (inbound.tag == "service-mixed-in" && inbound.listen_port != null) {
            let port = int(inbound.listen_port, 10);
            if (port > 0) {
                let host = as_string(inbound.listen || "127.0.0.1");
                if (host == "0.0.0.0" || host == "::" || host == "") host = "127.0.0.1";
                return { host: host, port: port, tag: inbound.tag };
            }
        }
    }
    for (let inbound in parsed.inbounds) {
        if ((inbound.type == "mixed" || inbound.type == "http") && inbound.listen_port != null) {
            let listen = as_string(inbound.listen || "");
            if (listen == "127.0.0.1" || listen == "0.0.0.0" || listen == "::" || listen == "") {
                let port = int(inbound.listen_port, 10);
                if (port > 0) return { host: "127.0.0.1", port: port, tag: inbound.tag };
            }
        }
    }
    for (let inbound in parsed.inbounds) {
        if ((inbound.type == "mixed" || inbound.type == "http") && inbound.listen_port != null) {
            let port = int(inbound.listen_port, 10);
            if (port > 0) {
                let host = as_string(inbound.listen || "127.0.0.1");
                if (host == "0.0.0.0" || host == "::" || host == "") host = "127.0.0.1";
                return { host: host, port: port, tag: inbound.tag };
            }
        }
    }
    return null;
}

function get_mixed_port() {
    let info = get_mixed_proxy_info();
    return info ? info.port : 4534;
}

function get_mixed_proxy_endpoint() {
    let info = get_mixed_proxy_info();
    if (!info) return null;
    return info.host + ":" + info.port;
}

function mixed_port_alive() {
    let now = time();
    if (mixed_port_alive_cached != null && (now - mixed_port_checked_at) < MIXED_PORT_PROBE_TTL)
        return mixed_port_alive_cached;

    let alive = false;
    let port = get_mixed_port();
    let out = command_output_from_args([ "netstat", "-ltn" ]);
    for (let line in split(out, "\n")) {
        if (index(line, ":" + port + " ") >= 0) {
            alive = true;
            break;
        }
    }

    mixed_port_alive_cached = alive;
    mixed_port_checked_at = now;
    return alive;
}

function direct_fallback_enabled() {
    return trim(as_string(settings().bot_direct_fallback || "1")) != "0";
}

function get_proxy_args() {
    let cfg = settings();
    if (command_success_from_args(["pidof", "sing-box"])) {
        let ep = get_mixed_proxy_endpoint() || ("127.0.0.1:" + get_mixed_port());
        if (!mixed_port_alive()) {
            if (direct_fallback_enabled())
                return [];
            return [ "--proxy", "http://" + ep ];
        }
        let bot_section = cfg.bot_proxy_section ? trim(cfg.bot_proxy_section) : "";
        if (bot_section != "") {
            let tag = bot_section + "-out";
            api.clash_request("PUT", "proxies/GLOBAL", { name: tag });
        }
        return [ "--proxy", "http://" + ep ];
    }
    if (cfg.fallback_socks && trim(cfg.fallback_socks) != "") {
        return [ "--proxy", "socks5h://" + trim(cfg.fallback_socks) ];
    }
    return [];
}

// ─── Telegram API Core ───────────────────────────────────────────────────────

function write_heartbeat() {
    write_text_file(HEARTBEAT_FILE, as_string(time()) + "\n");
}

function rotate_log_if_needed() {
    let st = fs.stat(LOG_FILE);
    if (!st || int(st.size || 0) <= LOG_MAX_BYTES)
        return;
    let data = fs.readfile(LOG_FILE);
    if (data == null)
        return;
    let tail = substr(data, length(data) - LOG_KEEP_BYTES);
    let newline = index(tail, "\n");
    if (newline >= 0)
        tail = substr(tail, newline + 1);
    fs.writefile(LOG_FILE, "--- log truncated (size cap) ---\n" + tail);
}

function tg_request_via(token, method, payload, proxy_args) {
    if (!token) return null;
    let url = "https://api.telegram.org/bot" + token + "/" + method;
    let body = sprintf("%J", payload);
    let is_poll = (method == "getUpdates");
    let max_time = is_poll ? "65" : "12";
    let conn_timeout = is_poll ? "15" : "5";
    let args = [ "curl", "-s", "-m", max_time, "--connect-timeout", conn_timeout,
                 "-X", "POST", "-H", "Content-Type: application/json",
                 "-d", body ];
    for (let p in proxy_args) push(args, p);
    push(args, url);
    let res = command_capture(command_from_args(args));
    if (!res || res.status != 0 || res.output == "") return null;
    try { return json(res.output); } catch (e) { return null; }
}

function tg_request(token, method, payload) {
    if (!token) return null;

    let proxy_args = get_proxy_args();
    let res = tg_request_via(token, method, payload, proxy_args);
    if (res != null)
        return res;

    if (direct_fallback_enabled() && length(proxy_args) > 0)
        res = tg_request_via(token, method, payload, []);

    return res;
}

function send_message(token, chat_id, text, parse_mode, keyboard) {
    let t = get_t();
    text = as_string(text);
    if (length(text) > 3900) {
        text = substr(text, 0, 3900) + "\n... " + t("msg_truncated");
        if (parse_mode == "HTML") {
            if (index(text, "<pre>") >= 0 && index(text, "</pre>") < 0) text += "</pre>";
            if (index(text, "<code>") >= 0 && index(text, "</code>") < 0) text += "</code>";
            if (index(text, "<b>") >= 0 && index(text, "</b>") < 0) text += "</b>";
            if (index(text, "<i>") >= 0 && index(text, "</i>") < 0) text += "</i>";
        }
    }
    let payload = { chat_id: int(chat_id), text: text };
    if (parse_mode) payload.parse_mode = parse_mode;
    if (keyboard) payload.reply_markup = { inline_keyboard: keyboard };
    let res = tg_request(token, "sendMessage", payload);
    if ((!res || !res.ok) && parse_mode) {
        delete payload.parse_mode;
        payload.text = replace(text, /<[^>]+>/g, "");
        res = tg_request(token, "sendMessage", payload);
    }
    return res;
}

function alert_route_failure(attempt, proxy_alive) {
    let t = get_t();
    let cfg = settings();
    let token = trim(as_string(cfg.bot_token || ""));
    if (token == "") return;
    let admins = split(trim(as_string(cfg.admin_ids || "")), /,/);
    let chat_id = trim(as_string(admins[0] || ""));
    if (chat_id == "") return;

    let hint = proxy_alive
        ? t("route_proxy_alive")
        : t("route_proxy_down");
    let text = "⚠️ <b>" + t("route_alert_title") + "</b> " + as_string(attempt) +
        " " + t("route_alert_consecutive") + ".\n" +
        t("route_reason") + " " + hint + ".\n" +
        t("route_fallback_hint") + "\n" +
        t("route_heal_hint");
    send_message(token, chat_id, text, "HTML", null);
}

function edit_message(token, chat_id, message_id, text, parse_mode, keyboard) {
    let t = get_t();
    text = as_string(text);
    if (length(text) > 3900) {
        text = substr(text, 0, 3900) + "\n... " + t("msg_truncated");
        if (parse_mode == "HTML") {
            if (index(text, "<pre>") >= 0 && index(text, "</pre>") < 0) text += "</pre>";
            if (index(text, "<code>") >= 0 && index(text, "</code>") < 0) text += "</code>";
            if (index(text, "<b>") >= 0 && index(text, "</b>") < 0) text += "</b>";
            if (index(text, "<i>") >= 0 && index(text, "</i>") < 0) text += "</i>";
        }
    }
    let payload = { chat_id: int(chat_id), message_id: int(message_id), text: text };
    if (parse_mode) payload.parse_mode = parse_mode;
    if (keyboard) payload.reply_markup = { inline_keyboard: keyboard };
    let res = tg_request(token, "editMessageText", payload);
    if ((!res || !res.ok) && parse_mode) {
        delete payload.parse_mode;
        payload.text = replace(text, /<[^>]+>/g, "");
        res = tg_request(token, "editMessageText", payload);
    }
    return res;
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

function register_bot_commands(token) {
    if (!token) return;
    let t = get_t();
    let commands = [
        { command: "menu",      description: t("cmd_menu") },
        { command: "status",    description: t("cmd_status") },
        { command: "runtime",   description: t("cmd_runtime") },
        { command: "outbounds", description: t("cmd_outbounds") },
        { command: "sections",  description: t("cmd_sections") },
        { command: "instances", description: t("cmd_instances") },
        { command: "guest",     description: t("cmd_guest") },
        { command: "speed",     description: t("cmd_speed") },
        { command: "ping",      description: t("cmd_ping") },
        { command: "test",      description: t("cmd_test") },
        { command: "logs",      description: t("cmd_logs") },
        { command: "info",      description: t("cmd_info") },
        { command: "connections", description: t("cmd_connections") },
        { command: "test_rule", description: t("cmd_test_rule") },
        { command: "help",      description: t("cmd_help") },
        { command: "check_updates", description: t("cmd_check_updates") },
        { command: "close_connections", description: t("cmd_close_connections") },
        { command: "doctor",    description: t("cmd_doctor") },
        { command: "restart",   description: t("cmd_restart") },
        { command: "lang",      description: t("cmd_lang") },
        { command: "fptn",      description: t("fptn_token_btn") }
    ];
    tg_request(token, "setMyCommands", { commands: commands });
}

// ─── State Management ────────────────────────────────────────────────────────

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
    if (data) { try { return json(data); } catch(e) {} }
    return null;
}

function set_tg_state(chat_id, state_obj) {
    let f = tg_state_path(chat_id);
    if (!f) return;
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

return {
    CONFIG_NAME,
    CB_MAP_FILE,
    CB_MAP_MAX,
    HEARTBEAT_FILE,
    LOG_FILE,
    LOG_MAX_BYTES,
    LOG_KEEP_BYTES,
    MIXED_PORT_PROBE_TTL,
    get_t,
    cb_map_load,
    cb_map_store,
    cb_map_get,
    cb_data,
    settings,
    get_mixed_proxy_info,
    get_mixed_port,
    get_mixed_proxy_endpoint,
    mixed_port_alive,
    direct_fallback_enabled,
    get_proxy_args,
    write_heartbeat,
    rotate_log_if_needed,
    tg_request_via,
    tg_request,
    send_message,
    alert_route_failure,
    edit_message,
    send_document,
    get_file_url,
    register_bot_commands,
    tg_state_path,
    get_tg_state,
    set_tg_state,
    is_admin
};
