#!/usr/bin/env ucode
//
// Telegram bot worker loop, poll processing, notifications and runtime lifecycle.
// Extracted from service/telegram.uc (Branch 7 god-module refactor).
//

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let api = require("service.api");
let i18n = require("service.i18n");

let rendering = require("service.telegram.rendering");
let transport = require("service.telegram.transport");
let commands = require("service.telegram.commands");
let callbacks = require("service.telegram.callbacks");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const BIN_PATH = getenv("TACHYON_BIN") || "/usr/bin/tachyon";
const NFT_TABLE_NAME = getenv("NFT_TABLE_NAME") || "TachyonTable";
const PID_FILE = "/var/run/tachyon_telegram.pid";
const OFFSET_FILE = "/var/run/tachyon_telegram_offset";
const COMPONENT_UPDATE_CHECK_TIMESTAMP = "/var/run/tachyon/component-update-check.timestamp";

let as_string = common.as_string;
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
let cb_map_get = transport.cb_map_get;
let get_file_url = transport.get_file_url;
let tg_request = transport.tg_request;
let tg_request_via = transport.tg_request_via;
let is_admin = transport.is_admin;
let get_tg_state = transport.get_tg_state;
let set_tg_state = transport.set_tg_state;
let get_proxy_args = transport.get_proxy_args;
let get_mixed_port = transport.get_mixed_port;
let get_mixed_proxy_endpoint = transport.get_mixed_proxy_endpoint;
let mixed_port_alive = transport.mixed_port_alive;
let direct_fallback_enabled = transport.direct_fallback_enabled;
let write_heartbeat = transport.write_heartbeat;
let rotate_log_if_needed = transport.rotate_log_if_needed;
let alert_route_failure = transport.alert_route_failure;
let settings = transport.settings;
let register_bot_commands = transport.register_bot_commands;

let format_bytes = rendering.format_bytes;
let escape_html = rendering.escape_html;
let apply_backup_restore = callbacks.apply_backup_restore;
let dispatch_command = callbacks.dispatch_command;
let view_set_arr = commands.view_set_arr;
let view_section_editor = commands.view_section_editor;

let t = i18n.bind("en");

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
    
    let is_critical = (index(message, t("critical_keyword_fallen")) >= 0 || index(message, t("critical_keyword_error")) >= 0);
    if (!is_critical && in_quiet_hours(cfg)) return 0;
    
    let admins = split(cfg.admin_ids, /,/);
    for (let admin in admins) {
        let chat_id = trim(admin);
        if (chat_id != "") send_message(cfg.bot_token, chat_id, message, "Markdown", null);
    }
    return 0;
}

function send_daily_digest(token, admin_ids) {
    let text = "📊 <b>" + t("daily_digest_title") + "</b>\n\n";
    let uptime_out = command_output_from_args(["uptime"]);
    let m = match(uptime_out, /up ([^,]+)/);
    let up = m ? m[1] : t("status_unknown");
    text += "⏱ " + t("daily_uptime") + ": " + up + "\n";
    
    let tr = api.get_clash_traffic ? api.get_clash_traffic() : null;
    if (tr && tr.down != null && tr.up != null) {
        text += "🔻 " + t("daily_rx") + ": " + format_bytes(tr.down) + "/s\n";
        text += "🔺 " + t("daily_tx") + ": " + format_bytes(tr.up) + "/s\n";
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
                        msg = "📦 <b>" + t("update_new_release_header") + "</b>\n" + title + ": <code>" + escape_html(cur) + "</code>" +
                            (transition != "" ? "\n" + t("update_build_label") + ": " + transition : "");
                    } else {
                        msg = "📦 <b>" + t("update_available") + "</b>\n" + title + ": <code>" + escape_html(cur) + "</code> ➡️ <code>" + escape_html(as_string(latest)) + "</code>";
                    }
                    let kb = [[{text: t("btn_update_component") + " " + title, callback_data: "/update_component " + name}]];

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

function notify_updates_cli() {
    let cfg = settings();
    if (cfg.enabled != "1" || !cfg.bot_token || !cfg.admin_ids) return 0;
    check_notified_updates(cfg.bot_token, cfg.admin_ids);
    return 0;
}

function block_schedules_with_notify() {
    let result = [];
    for (let s in uci_core.sections(CONFIG_NAME, "schedule")) {
        s = object_or_empty(s);
        if (option(s, "enabled", "1") != "0" &&
            option(s, "notify", "0") == "1" &&
            length(common.list_option(s, "blocked_domains")) > 0)
            push(result, s);
    }
    return result;
}

function load_blocked_counts() {
    try {
        let raw = trim(fs.readfile(BLOCKED_STATE_FILE) || "");
        if (raw == "") return {};
        return json(raw);
    } catch (e) {
        return {};
    }
}

function save_blocked_counts(counts) {
    try {
        fs.writefile(BLOCKED_STATE_FILE, sprintf("%J", counts));
    } catch (e) {}
}

function check_blocked_activity(cfg) {
    let schedules = block_schedules_with_notify();
    if (length(schedules) == 0) return;

    let out = command_capture(command_from_args([ "nft", "list", "chain", "inet", NFT_TABLE_NAME, "dns_block" ]));
    if (!out || out.status != 0) return;

    let previous = load_blocked_counts();
    let current = {};
    for (let schedule in schedules) {
        let label = as_string(option(schedule, "label", schedule[".name"]));
        let needle = "tachyon-block:" + label;
        let total = 0;
        let match_count = 0;
        for (let line in split(out.output || "", "\n")) {
            if (index(line, needle) < 0)
                continue;
            let m = match(line, /packets[= ]+([0-9]+)/);
            if (!m || !m[1]) continue;
            total += int(m[1]);
            match_count++;
        }
        if (match_count == 0)
            continue;
        current[label] = total;
        let prev = int(previous[label] || "0");
        if (total > prev) {
            let delta = total - prev;
            let admins = split(cfg.admin_ids || "", /,/);
            for (let admin in admins) {
                let cid = trim(admin);
                if (cid != "")
                    send_message(cfg.bot_token, cid,
                        "🚫 <b>" + t("blocked_activity") + "</b>\n" +
                        t("blocked_rule") + ": <code>" + escape_html(label) + "</code>\n" +
                        t("blocked_attempts") + ": <code>" + as_string(delta) + "</code>",
                        "HTML", null);
            }
        }
    }
    save_blocked_counts(current);
}

function process_updates(token, admin_ids) {
    let offset = int(trim(fs.readfile(OFFSET_FILE) || "0"));
    let res = tg_request(token, "getUpdates", { offset: offset, timeout: 50 });
    
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
                send_message(token, chat_id, "❌ " + t("exec_cmd_error") + " " + escape_html(as_string(e)), "HTML");
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
                    send_message(token, chat_id, "❌ " + t("exec_access_denied") + " `" + chat_id + "`", "Markdown");
                }
                continue;
            }

            if (msg.document) {
                let doc = msg.document;
                if (match(doc.file_name || "", /\.tar\.gz$/)) {
                    send_message(token, chat_id, "⏳ <b>" + t("backup_downloading") + "</b>", "HTML");
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
                            send_message(token, chat_id, "❌ <b>" + t("backup_download_error") + "</b>", "HTML");
                        }
                    } else {
                        send_message(token, chat_id, "❌ <b>" + t("backup_url_error") + "</b>", "HTML");
                    }
                } else {
                    send_message(token, chat_id, "ℹ️ " + t("backup_format_hint"), "Markdown");
                }
                continue;
            }

            if (msg.forward_from) {
                let fwd_id = msg.forward_from.id;
                let text = "👤 " + t("admin_forward_prompt") + " `" + fwd_id + "`.\nДобавить его в список администраторов бота?";
                let keyboard = [[{text: t("btn_admin_add"), callback_data: "/admin_add " + fwd_id}]];
                send_message(token, chat_id, text, "Markdown", keyboard);
                continue;
            }

            if (msg.text) {
                if (match(msg.text, /^> /)) {
                    let exec_cmd = trim(substr(msg.text, 2));
                    send_message(token, chat_id, "⏳ " + t("exec_whitelist_msg") + "\n<code>" + escape_html(exec_cmd) + "</code>", "HTML");
                    let out = safe_execute(exec_cmd);
                    let result_text = "<b>Выполнено (код " + out.status + "):</b>\n<pre>" + escape_html(out.output || t("exec_no_output")) + "</pre>";
                    if (length(result_text) > 4000) result_text = substr(result_text, 0, 4000) + "...</pre>";
                    send_message(token, chat_id, result_text, "HTML");
                    continue;
                }

                if (msg.text == "/cancel") {
                    set_tg_state(chat_id, null);
                    send_message(token, chat_id, "❌ " + t("action_cancelled"), "HTML", [[{text:"⬅️ " + t("nav_menu"), callback_data:"/menu"}]]);
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
                    send_message(token, chat_id, "⚠️ " + t("err_text_expected"), "HTML");
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
                        send_message(token, chat_id, "❌ " + t("exec_nothing_added"));
                    }
                    view_sec_list(token, chat_id, null, state.sec, state.list);
                }
                else if (state.action == "test_rule") {
                    view_test_rule(token, chat_id, null, trim(msg.text));
                }
                else if (state.action == "sub_add") {
                    handle_sub_add(token, chat_id, msg_id, trim(msg.text));
                }
                else if (state.action == "sec_sub_add") {
                    let parts = split(trim(msg.text), " ");
                    if (length(parts) >= 2) {
                        let sec = parts[0];
                        let url = join(" ", slice(parts, 1));
                        handle_sec_sub_add(token, chat_id, msg_id, sec, url);
                    } else {
                        set_tg_state(chat_id, state);
                        send_message(token, chat_id, "❌ Формат: <code>секция URL</code>\nНапример: <code>Main https://...</code>", "HTML");
                    }
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
                else if (state.action == "fptn_token") {
                    set_tg_state(chat_id, null);
                    handle_fptn_token_update(token, chat_id, trim(msg.text), state.sec || null);
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

function worker() {
    let cfg = settings();
    if (cfg.enabled != "1" || !cfg.bot_token) return 0;

    write_heartbeat();
    t = i18n.bind(cfg.language);
    register_bot_commands(cfg.bot_token);

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
    let last_update_check_mtime = 0;
    let last_blocked_check = 0;
    let consecutive_failures = 0;
    let route_alert_sent = false;
    let last_log_check = 0;

    while (true) {
        try {
            cfg = settings();
            if (cfg.enabled != "1") break;
            t = i18n.bind(cfg.language);
            write_heartbeat();
            let res = process_updates(cfg.bot_token, cfg.admin_ids);

            if (res === false) {
                consecutive_failures++;
                let backoff = poll_interval * (1 << min(consecutive_failures - 1, 4));
                if (backoff > 300) backoff = 300;
                let log_level = consecutive_failures >= 3 ? "[warn]" : "[info]";
                command_success_from_args(["logger", "-t", "tachyon-telegram", log_level + " API poll retry " + as_string(consecutive_failures) + ", backing off " + as_string(backoff) + "s"]);

                // Tell the admin once per failure episode that the usual
                // proxy route is down and the direct fallback carries the
                // bot meanwhile.
                if (!route_alert_sent && consecutive_failures >= 5) {
                    route_alert_sent = true;
                    alert_route_failure(consecutive_failures, mixed_port_alive());
                }

                sleep(backoff * 1000);
                continue;
            }
            consecutive_failures = 0;
            route_alert_sent = false;
            write_heartbeat();

            let now = time();
            // localtime() yields { sec, min, hour, mday, mon, year, ... }.
            // clock() returns [seconds, microseconds] and has no calendar fields.
            let tm = localtime(now);
            let daily_hour = int(cfg.daily_report_hour || "8");

            if (cfg.daily_report_enabled == "1" && tm && tm.hour == daily_hour && tm.mday != last_report_day) {
                last_report_day = tm.mday;
                send_daily_digest(cfg.bot_token, cfg.admin_ids);
            }
            
            let ts_stat = fs.stat(COMPONENT_UPDATE_CHECK_TIMESTAMP);
            let ts_mtime = ts_stat ? int(ts_stat.mtime || 0) : 0;
            if (ts_mtime > 0 && ts_mtime != last_update_check_mtime) {
                last_update_check_mtime = ts_mtime;
                check_notified_updates(cfg.bot_token, cfg.admin_ids);
                last_update_check = now;
            } else if (now - last_update_check > 3600) {
                check_notified_updates(cfg.bot_token, cfg.admin_ids);
                last_update_check = now;
            }

            if (now - last_blocked_check > BLOCKED_POLL_INTERVAL) {
                check_blocked_activity(cfg);
                last_blocked_check = now;
            }

            if (now - last_log_check > 3600) {
                rotate_log_if_needed();
                last_log_check = now;
            }
        } catch (e) {
            consecutive_failures++;
            command_success_from_args(["logger", "-t", "tachyon-telegram", "[err] Worker loop error: " + as_string(e)]);
            sleep(poll_interval * 1000);
        }
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
    // Also kill any orphaned telegram workers not tracked by the PID file.
    // These accumulate when the PID file is stale after a crash/restart.
    command_success_from_args([ "sh", "-c", "pgrep -f 'telegram.uc worker$' 2>/dev/null | xargs kill 2>/dev/null; true" ]);
    // Absent file already satisfies the caller; fs.unlink throws on ENOENT.
    try { fs.unlink(PID_FILE); } catch(e) {}
    try { fs.unlink(HEARTBEAT_FILE); } catch(e) {}
    return 0;
}

function start_runtime() {
    let cfg = settings();
    stop_runtime();
    if (cfg.enabled != "1" || !cfg.bot_token) return 0;
    
    write_heartbeat();
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

function diagnose() {
    let cfg = settings();
    let checks = [];
    let ok = true;

    // 1. bot_token
    if (cfg.bot_token) {
        push(checks, { name: "bot_token", ok: true, message: "bot_token is set" });
    } else {
        push(checks, { name: "bot_token", ok: false, message: "bot_token is empty — set token first" });
        ok = false;
    }

    // 2. admin_ids
    if (cfg.admin_ids && trim(cfg.admin_ids) !== "") {
        push(checks, { name: "admin_ids", ok: true, message: "admin_ids is set: " + cfg.admin_ids });
    } else {
        push(checks, { name: "admin_ids", ok: false, message: "admin_ids is empty — cannot send messages" });
        ok = false;
    }

    // 3. sing-box running
    let sb_running = command_success_from_args(["pidof", "sing-box"]);
    push(checks, {
        name: "sing_box",
        ok: sb_running,
        message: sb_running ? "sing-box is running" : "sing-box is NOT running — proxy routing unavailable"
    });

    // 4. Mixed proxy port
    let proxy_info = get_mixed_proxy_info();
    let proxy_ep = proxy_info ? (proxy_info.host + ":" + proxy_info.port) : null;
    let port_ok = false;
    if (proxy_info) {
        let port_check = command_capture("netstat -tlnp 2>/dev/null | grep ':" + proxy_info.port + " '");
        port_ok = port_check && port_check.status === 0 && trim(port_check.output || "") !== "";
        push(checks, {
            name: "proxy_port",
            ok: port_ok,
            message: port_ok ? "Mixed proxy port " + proxy_info.port + " is listening (" + proxy_info.host + ")" : "Port " + proxy_info.port + " not listening — proxy may not be available"
        });
    } else {
        push(checks, {
            name: "proxy_port",
            ok: true,
            message: "Mixed proxy is not configured in sing-box — bot will use direct connection"
        });
    }

    // 5. DNS resolution
    let dns_check = command_capture("nslookup api.telegram.org 2>/dev/null");
    let dns_out = (dns_check && dns_check.output) || "";
    // Accept real IPs (149.154/91.108) or sing-box FakeIP range (198.18.x.x/198.19.x.x)
    let dns_ok = dns_check && dns_check.status === 0 && index(dns_out, "Address") >= 0
        && (index(dns_out, "149.154") >= 0 || index(dns_out, "91.108") >= 0
            || index(dns_out, "198.18.") >= 0 || index(dns_out, "198.19.") >= 0);
    push(checks, {
        name: "dns",
        ok: dns_ok,
        message: dns_ok ? "DNS resolves api.telegram.org" : "DNS cannot resolve api.telegram.org — check DNS settings"
    });

    // 6. Direct API test (IPv4)
    let d_ok = false;
    if (cfg.bot_token) {
        let direct = command_capture(command_from_args([
            "curl", "-s", "-4", "--connect-timeout", "5", "--max-time", "8",
            "https://api.telegram.org/bot" + cfg.bot_token + "/getMe"
        ]));
        let d_out = (direct && direct.output) || "";
        d_ok = direct && direct.status === 0 && index(d_out, '"ok":true') >= 0;
        let d_msg = d_ok
            ? "Direct IPv4 to Telegram API works"
            : (index(d_out, '"ok":false') >= 0
                ? "API returned error — token may be invalid"
                : "Cannot reach Telegram API directly (IPv4 may be blocked by ISP)");
        push(checks, { name: "direct_api", ok: d_ok, message: d_msg });
    }

    // 7. Proxy API test
    let p_ok = false;
    if (cfg.bot_token && sb_running && proxy_info && port_ok) {
        let proxied = command_capture(command_from_args([
            "curl", "-s", "-4", "--connect-timeout", "5", "--max-time", "8",
            "--proxy", "http://" + proxy_ep,
            "https://api.telegram.org/bot" + cfg.bot_token + "/getMe"
        ]));
        let p_out = (proxied && proxied.output) || "";
        p_ok = proxied && proxied.status === 0 && index(p_out, '"ok":true') >= 0;
        push(checks, {
            name: "proxy_api",
            ok: p_ok,
            message: p_ok ? "Proxy route (" + proxy_ep + ") to Telegram API works" : "Proxy route failed — check sing-box outbound for Telegram"
        });
    } else if (proxy_info && !port_ok) {
        push(checks, {
            name: "proxy_api",
            ok: false,
            message: "Proxy route skipped — mixed proxy port " + proxy_info.port + " is not listening"
        });
    }

    // Route check: at least one connection method must work
    let route_ok = d_ok || p_ok;
    if (!route_ok) ok = false;

    // 8. Send test message
    if (cfg.bot_token && cfg.admin_ids) {
        let first_admin = trim(split(cfg.admin_ids, /,/)[0] || "");
        if (first_admin !== "") {
            let s_ok = send_message(cfg.bot_token, first_admin, "✅ Tachyon connection test passed");
            push(checks, {
                name: "send_message",
                ok: s_ok,
                message: s_ok
                    ? "Test message sent to chat " + first_admin
                    : "Failed to send test message — check admin_ids and bot permissions"
            });
            if (!s_ok) ok = false;
        }
    }

    print(sprintf("%J", { ok: ok, checks: checks }));
    return ok ? 0 : 1;
}

return {
    in_quiet_hours,
    send_api,
    send_daily_digest,
    check_notified_updates,
    notify_updates_cli,
    block_schedules_with_notify,
    load_blocked_counts,
    save_blocked_counts,
    check_blocked_activity,
    process_updates,
    worker,
    stop_runtime,
    start_runtime,
    get_status,
    diagnose
};
