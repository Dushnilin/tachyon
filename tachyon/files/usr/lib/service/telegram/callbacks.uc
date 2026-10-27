#!/usr/bin/env ucode
//
// Telegram bot callback query handlers and command dispatcher.
// Extracted from service/telegram.uc (Branch 7 god-module refactor).
//

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let connections = null;
function get_connections() {
    if (connections == null) connections = require("config.connections");
    return connections;
}
let dns_presets = null;
function get_dns_presets() {
    if (dns_presets == null) dns_presets = require("tachyon_core.dns_presets");
    return dns_presets;
}
let api = require("service.api");
let i18n = require("service.i18n");

let rendering = require("service.telegram.rendering");
let transport = require("service.telegram.transport");
let commands = require("service.telegram.commands");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";

let as_string = common.as_string;
let option = common.option;
let bool_option = common.bool_option;
// Same missing binding as runtime.uc after the split in 57c7e2b0: reachable
// from handle_switch() below, so choosing a node through the proxy group threw
// instead of persisting the choice.
let save_persistent_selector_choice = commands.save_persistent_selector_choice;
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
let cb_map_get = transport.cb_map_get;
let get_file_url = transport.get_file_url;
let tg_request = transport.tg_request;
let is_admin = transport.is_admin;
let get_tg_state = transport.get_tg_state;
let set_tg_state = transport.set_tg_state;
let get_proxy_args = transport.get_proxy_args;
let settings = transport.settings;
let register_bot_commands = transport.register_bot_commands;

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
let backup_archive_members = rendering.backup_archive_members;
let backup_archive_safe = rendering.backup_archive_safe;
let backup_extract_dir = rendering.backup_extract_dir;
let config_sane_preview = rendering.config_sane_preview;

let view_settings_menu = commands.view_settings_menu;
let view_set_list = commands.view_set_list;
let view_set_cat = commands.view_set_cat;
let view_set_arr = commands.view_set_arr;
let view_menu = commands.view_menu;
let view_status = commands.view_status;
let view_runtime = commands.view_runtime;
let view_outbounds = commands.view_outbounds;
let view_sections = commands.view_sections;
let view_section_editor = commands.view_section_editor;
let view_sec_conds = commands.view_sec_conds;
let view_sec_bals = commands.view_sec_bals;
let view_sec_grp = commands.view_sec_grp;
let view_sec_list = commands.view_sec_list;
let exec_doctor = commands.exec_doctor;
let exec_restart = commands.exec_restart;
let restore_config_from_backup = commands.restore_config_from_backup;
let exec_backup = commands.exec_backup;
let exec_support_bundle = commands.exec_support_bundle;
let exec_close_connections = commands.exec_close_connections;
let exec_check_updates = commands.exec_check_updates;
let view_instances = commands.view_instances;
let exec_speedtest = commands.exec_speedtest;
let view_ping = commands.view_ping;
let view_quick_test = commands.view_quick_test;
let view_logs = commands.view_logs;
let view_system_info = commands.view_system_info;
let view_connections = commands.view_connections;
let view_sec_subs = commands.view_sec_subs;
let view_help = commands.view_help;
let view_router_name = commands.view_router_name;
let view_language = commands.view_language;
let view_guest_mode = commands.view_guest_mode;
let view_quiet_hours = commands.view_quiet_hours;
let view_test_rule = commands.view_test_rule;
let exec_export_config = commands.exec_export_config;
let view_devices = commands.view_devices;
let view_watchdog = commands.view_watchdog;
let exec_ai_heal = commands.exec_ai_heal;
let exec_ai_status_full = commands.exec_ai_status_full;
let view_qos = commands.view_qos;

let t = i18n.bind("en");

function handle_set_tog(token, chat_id, msg_id, stype, sname, key, page) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let s = c.get_all(CONFIG_NAME, sname);
    if (!s) return;
    let b = (s[key] == "1" || s[key] == "true");
    c.set(CONFIG_NAME, sname, key, b ? "0" : "1");
    c.commit(CONFIG_NAME);
    if (key == "enabled") {
        command_status(command_from_args(["/usr/bin/tachyon", "reload", "force"]));
    }
    return view_set_cat(token, chat_id, msg_id, stype, sname, page);
}

function handle_set_del(token, chat_id, msg_id, stype, sname) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    c.delete(CONFIG_NAME, sname);
    c.commit(CONFIG_NAME);
    command_status(command_from_args(["/usr/bin/tachyon", "reload", "force"]));
    send_message(token, chat_id, "🗑️ <b>Deleted:</b> <code>" + escape_html(sname) + "</code>", "HTML");
    return view_set_list(token, chat_id, null, stype);
}

function handle_fptn_token_update(token, chat_id, raw_input, target_sec) {
    let clean_tok = extract_clean_fptn_token(raw_input);
    if (clean_tok == "") {
        send_message(token, chat_id, "❌ " + t("fptn_token_invalid"), "HTML", [
            [{ text: "⬅️ " + t("nav_menu"), callback_data: "/menu" }]
        ]);
        return false;
    }

    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let all = c.get_all(CONFIG_NAME);
    let fptn_count = 0;

    if (target_sec && all[target_sec]) {
        c.set(CONFIG_NAME, target_sec, "access_token", clean_tok);
        for (let src in section_outbound_sources(all[target_sec])) {
            if (src.source_type == "fptn" && src[".name"])
                c.set(CONFIG_NAME, src[".name"], "access_token", clean_tok);
        }
        fptn_count++;
    } else {
        for (let sname in keys(all)) {
            let s = all[sname];
            if (type(s) == "object" && (s.action == "fptn" || (s[".type"] == "outbound_source" && s.source_type == "fptn"))) {
                c.set(CONFIG_NAME, sname, "access_token", clean_tok);
                fptn_count++;
            }
        }
    }

    c.commit(CONFIG_NAME);

    try {
        let fc = uci_core.cursor();
        if (fc.load("fptn")) {
            if (fc.get_all("fptn", "config")) {
                fc.set("fptn", "config", "access_token", clean_tok);
                fc.commit("fptn");
            }
        }
    } catch (e) {}

    let masked = mask_fptn_token(clean_tok);

    if (fptn_count == 0) {
        let msg = "⚠️ <b>" + t("fptn_token_no_section") + "</b>\nToken: <code>" + escape_html(masked) + "</code>";
        send_message(token, chat_id, msg, "HTML", [
            [{ text: "⬅️ " + t("nav_menu"), callback_data: "/menu" }]
        ]);
        return true;
    }

    send_message(token, chat_id, "⏳ <b>" + t("fptn_token_saved_connecting") + "</b>\nToken: <code>" + escape_html(masked) + "</code>", "HTML");

    // Restart FPTN runtime
    command_status(command_from_args([ "ucode", "-L", LIB_DIR, LIB_DIR + "/providers/fptn/runtime.uc", "restart-runtime" ]));

    // Poll up to 5 seconds for tun-fptn and table 4249 routing
    let connected = false;
    for (let i = 0; i < 5; i++) {
        let out = command_output_from_args([ "ucode", "-L", LIB_DIR, LIB_DIR + "/providers/fptn/runtime.uc", "status" ]);
        try {
            let st = json(out);
            if (st && st.running && st.tun_up && st.route_installed) {
                connected = true;
                break;
            }
        } catch (e) {}
        command_status(command_from_args([ "sleep", "1" ]));
    }

    if (connected) {
        let msg = "✅ <b>" + t("fptn_token_updated_title") + "</b>\n" +
                  "Token: <code>" + escape_html(masked) + "</code>\n" +
                  "Status: 🟢 Connected (tun-fptn & routing ready)";
        send_message(token, chat_id, msg, "HTML", [
            [{ text: "⬅️ " + t("nav_menu"), callback_data: "/menu" }]
        ]);
    } else {
        let msg = "⚠️ <b>" + t("fptn_token_saved_connecting") + "</b>\n" +
                  "Token: <code>" + escape_html(masked) + "</code>\n\n" +
                  t("fptn_token_retry_hint");
        send_message(token, chat_id, msg, "HTML", [
            [{ text: "⬅️ " + t("nav_menu"), callback_data: "/menu" }]
        ]);
    }

    return true;
}

function handle_switch(token, chat_id, msg_id, group_name, server_name) {
    api.clash_request("PUT", "proxies/" + group_name, { name: server_name });
    // A successful switch answers 204 with an empty body, which clash_request()
    // cannot distinguish from a failure — so verify by reading the state back.
    let data = api.get_clash_proxies_data();
    let grp = (data && data.proxies) ? data.proxies[group_name] : null;
    if (!grp || grp.now != server_name) {
        send_message(token, chat_id,
"⚠️ <b>" + t("outbound_switch_failed") + "</b>\n" +
             t("outbound_group") + ": <code>" + escape_html(group_name) + "</code>\n" +
             t("outbound_server") + ": <code>" + escape_html(server_name) + "</code>\n\n" +
             t("outbound_check_hint"), "HTML");
    } else {
        save_persistent_selector_choice(group_name, server_name);
    }
    view_outbounds(token, chat_id, msg_id, group_name);
}

function handle_sec_toggle(token, chat_id, msg_id, sec_name) {
    api.toggle_section(sec_name);
    return view_section_editor(token, chat_id, msg_id, sec_name);
}

function handle_sec_action(token, chat_id, msg_id, sec_name, explicit_act) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let s = c.get_all(CONFIG_NAME, sec_name);
    if (!s) return;
    let next_act = explicit_act;
    if (!next_act || next_act == "") {
        let acts = ["connection", "group", "dns", "bypass", "block", "hosts", "fptn", "awg"];
        let cur = (s.action == "proxy") ? "connection" : (s.action || "connection");
        let idx = -1;
        for (let i = 0; i < length(acts); i++) { if (acts[i] == cur) idx = i; }
        if (idx == -1) push(acts, cur);
        next_act = acts[(idx + 1) % length(acts)];
    }
    c.set(CONFIG_NAME, sec_name, "action", next_act);
    c.commit(CONFIG_NAME);
    return view_section_editor(token, chat_id, msg_id, sec_name);
}

function remove_item_from_holders(c, holders, keys_to_clean, val) {
    let match_variants = {};
    match_variants[val] = true;
    match_variants["." + val] = true;
    match_variants["domain:" + val] = true;
    match_variants["full:" + val] = true;
    match_variants["keyword:" + val] = true;
    match_variants["regex:" + val] = true;
    match_variants["regexp:" + val] = true;

    for (let h in holders) {
        if (type(h) != "object") continue;
        let hname = h[".name"];
        if (!hname || hname == "") continue;
        for (let k in keys_to_clean) {
            let current = common.list_option(h, k);
            if (length(current) > 0) {
                let new_list = [];
                let changed = false;
                for (let x in current) {
                    if (match_variants[trim(as_string(x))]) {
                        changed = true;
                    } else {
                        push(new_list, x);
                    }
                }
                if (changed) {
                    if (length(new_list) > 0) c.set(CONFIG_NAME, hname, k, new_list);
                    else c.delete(CONFIG_NAME, hname, k);
                }
            }
            let tval = trim(as_string(common.option(h, k + "_text", "")));
            if (tval != "") {
                let kept = [];
                let tchanged = false;
                for (let tok in split(tval, /[\r\n,;\t ]+/)) {
                    if (tok == "") continue;
                    if (match_variants[tok]) tchanged = true;
                    else push(kept, tok);
                }
                if (tchanged) {
                    if (length(kept) > 0) c.set(CONFIG_NAME, hname, k + "_text", join("\n", kept));
                    else c.delete(CONFIG_NAME, hname, k + "_text");
                }
            }
        }
    }
}

function handle_sec_del_it(token, chat_id, msg_id, sec_name, item_type, val) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let s = c.get_all(CONFIG_NAME, sec_name);
    if (!s) return;

    let keys_to_clean = [ item_type ];
    if (item_type == "domain_suffix" || item_type == "domain" || item_type == "domain_keyword" || item_type == "domain_regex" || item_type == "user_domains")
        keys_to_clean = [ item_type, "user_domains", "domain", "domain_suffix" ];
    else if (item_type == "source_ip_cidr" || item_type == "src_ip")
        keys_to_clean = [ "source_ip_cidr", "fully_routed_ips", "device_ip", "src_ip" ];
    else if (item_type == "source_macs" || item_type == "src_mac")
        keys_to_clean = [ "source_macs", "device_mac", "src_mac" ];
    else if (item_type == "devices" || item_type == "src_device")
        keys_to_clean = [ "devices", "src_device" ];
    else if (item_type == "ports" || item_type == "port")
        keys_to_clean = [ "ports", "port" ];

    remove_item_from_holders(c, section_own_and_conditions(s), keys_to_clean, val);
    c.commit(CONFIG_NAME);

    // figure out parent list_type
    let list_type = "domain";
    if (match(item_type, /^ip/) || item_type == "subnets") list_type = "ip";
    else if (match(item_type, /^src/) || item_type == "source_ip_cidr" || item_type == "source_macs" || item_type == "devices" || item_type == "fully_routed_ips" || item_type == "device_ip" || item_type == "device_mac") list_type = "src";
    else if (item_type == "community_lists" || item_type == "rule_set" || item_type == "rule_set_with_subnets" || item_type == "domain_ip_lists") list_type = "ruleset";
    else if (item_type == "ports" || item_type == "port") list_type = "ports";
    else if (item_type == "geoip_country") list_type = "geoip";

    return view_sec_list(token, chat_id, msg_id, sec_name, list_type);
}

function handle_sec_clear(token, chat_id, msg_id, sec_name, list_type) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let s = c.get_all(CONFIG_NAME, sec_name);
    if (!s) return;

    let keys = [];
    if (list_type == "domain")
        keys = ["user_domains", "user_domains_text", "domain", "domain_text", "domain_suffix", "domain_suffix_text", "domain_keyword", "domain_keyword_text", "domain_regex", "domain_regex_text"];
    else if (list_type == "ip")
        keys = ["ip", "ip_cidr", "ip_cidr_text", "subnets"];
    else if (list_type == "src")
        keys = ["src_ip", "source_ip_cidr", "source_ip_cidr_text", "fully_routed_ips", "device_ip", "src_mac", "source_macs", "device_mac", "src_device", "devices"];
    else if (list_type == "ruleset")
        keys = ["community_lists", "rule_set", "rule_set_with_subnets", "domain_ip_lists"];
    else if (list_type == "ports")
        keys = ["ports", "ports_text", "port"];
    else if (list_type == "geoip")
        keys = ["geoip_country"];

    for (let h in section_own_and_conditions(s)) {
        let hname = h[".name"];
        if (!hname) continue;
        for (let k in keys)
            c.delete(CONFIG_NAME, hname, k);
    }
    c.commit(CONFIG_NAME);
    return view_sec_list(token, chat_id, msg_id, sec_name, list_type);
}

function apply_confirmed_restart(token, chat_id, msg_id) {
    edit_message(token, chat_id, msg_id, "🔄 <b>" + t("restart_in_progress") + "</b>", "HTML");
    let st = command_status(command_from_args(["/usr/bin/tachyon", "restart"]));
    let text = (st == 0) ? "✅ <b>" + t("restart_success") + "</b>" : "❌ <b>" + t("restart_error") + "</b>";
    send_message(token, chat_id, text, "HTML", [[{text:t("nav_menu"), callback_data:"/menu"}]]);
}

function apply_backup_restore(token, chat_id, dl_path) {
    let members = backup_archive_members(dl_path);
    if (length(members) == 0) {
        fs.unlink(dl_path);
        send_message(token, chat_id, "❌ <b>" + t("backup_archive_empty") + "</b>", "HTML", [[{text:t("nav_menu"), callback_data:"/menu"}]]);
        return;
    }

    let safety = backup_archive_safe(members);
    if (!safety.ok) {
        fs.unlink(dl_path);
        send_message(token, chat_id, "❌ <b>" + t("backup_archive_unsafe") + "</b> " + escape_html(safety.reason), "HTML", [[{text:"⬅️ " + t("nav_menu"), callback_data:"/menu"}]]);
        return;
    }

    send_message(token, chat_id, "🔄 <b>" + t("backup_restoring") + "</b>", "HTML");

    let stage = backup_extract_dir();
    command_status(command_from_args([ "rm", "-rf", stage ]));
    if (command_status(command_from_args([ "mkdir", "-p", stage ])) != 0 ||
        command_status(command_from_args([ "tar", "-xzf", dl_path, "-C", stage ])) != 0) {
        command_status(command_from_args([ "rm", "-rf", stage ]));
        fs.unlink(dl_path);
        send_message(token, chat_id, "❌ <b>" + t("backup_extract_failed") + "</b>", "HTML", [[{text:"⬅️ " + t("nav_menu"), callback_data:"/menu"}]]);
        return;
    }
    fs.unlink(dl_path);

    let staged_config = stage + "/config/tachyon";
    let had_config = fs.stat(staged_config) != null;
    if (had_config && !config_sane_preview(staged_config)) {
        command_status(command_from_args([ "rm", "-rf", stage ]));
        send_message(token, chat_id, "❌ <b>" + t("backup_not_valid_uci") + "</b>", "HTML", [[{text:"⬅️ " + t("nav_menu"), callback_data:"/menu"}]]);
        return;
    }

    let staged_data = stage + "/tachyon";
    let had_data = fs.stat(staged_data) != null;
    if (!had_config && !had_data) {
        command_status(command_from_args([ "rm", "-rf", stage ]));
        send_message(token, chat_id, "❌ <b>" + t("backup_no_config") + "</b>", "HTML", [[{text:"⬅️ " + t("nav_menu"), callback_data:"/menu"}]]);
        return;
    }

    // Snapshot live targets so a failed reload can be rolled back
    let cfg_backup = "/etc/.tachyon/restore_cfg_backup." + as_string(time());
    if (fs.stat("/etc/config/tachyon")) {
        if (command_status(command_from_args([ "cp", "-a", "/etc/config/tachyon", cfg_backup ])) != 0) {
            command_status(command_from_args([ "rm", "-rf", stage ]));
            send_message(token, chat_id, "❌ <b>" + t("backup_save_config_failed") + "</b>", "HTML", [[{text:"⬅️ " + t("nav_menu"), callback_data:"/menu"}]]);
            return;
        }
    }
    let data_backup = "/etc/.tachyon/restore_data_backup." + as_string(time());
    if (fs.stat("/etc/tachyon")) {
        if (command_status(command_from_args([ "cp", "-a", "/etc/tachyon", data_backup ])) != 0) {
            command_status(command_from_args([ "rm", "-f", cfg_backup ]));
            command_status(command_from_args([ "rm", "-rf", stage ]));
            send_message(token, chat_id, "❌ <b>" + t("backup_save_data_failed") + "</b>", "HTML", [[{text:"⬅️ " + t("nav_menu"), callback_data:"/menu"}]]);
            return;
        }
    }

    // Apply staged config
    if (had_config) {
        if (command_status(command_from_args([ "cp", "-a", staged_config, "/etc/config/tachyon.restored" ])) != 0 ||
            command_status(command_from_args([ "mv", "/etc/config/tachyon.restored", "/etc/config/tachyon" ])) != 0) {
            restore_config_from_backup(cfg_backup);
            command_status(command_from_args([ "rm", "-rf", stage, data_backup, cfg_backup ]));
            send_message(token, chat_id, "❌ <b>" + t("backup_write_config_error") + "</b>", "HTML", [[{text:"⬅️ " + t("nav_menu"), callback_data:"/menu"}]]);
            return;
        }
        command_status(command_from_args([ "chmod", "600", "/etc/config/tachyon" ]));
        // Validate through the real UCI parser
        if (command_status(command_from_args([ "/sbin/uci", "show", "tachyon" ])) != 0) {
            restore_config_from_backup(cfg_backup);
            command_status(command_from_args([ "rm", "-rf", stage, data_backup, cfg_backup ]));
            send_message(token, chat_id, "❌ <b>" + t("backup_uci_validation_failed") + "</b>", "HTML", [[{text:"⬅️ " + t("nav_menu"), callback_data:"/menu"}]]);
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
            command_status(command_from_args([ "rm", "-rf", stage, data_backup, cfg_backup ]));
            send_message(token, chat_id, "❌ <b>" + t("backup_write_data_error") + "</b>", "HTML", [[{text:"⬅️ " + t("nav_menu"), callback_data:"/menu"}]]);
            return;
        }
    }

    command_status(command_from_args([ "rm", "-rf", stage ]));
    command_status(command_from_args([ "rm", "-f", cfg_backup ]));
    command_status(command_from_args([ "rm", "-rf", data_backup ]));

    send_message(token, chat_id, "✅ <b>" + t("backup_restored") + "</b>", "HTML");
    command_status(command_from_args([ "/usr/bin/tachyon", "restart" ]));
    send_message(token, chat_id, "✅ <b>" + t("backup_done") + "</b>", "HTML", [[{text:"⬅️ " + t("nav_menu"), callback_data:"/menu"}]]);
}

function toggle_ref_in_list(c, sec_name, list_key, item_name) {
    let s = c.get_all(CONFIG_NAME, sec_name);
    if (!s) return false;
    let current = common.list_option(s, list_key);
    let next = [];
    let found = false;
    for (let x in current) {
        if (x == item_name) found = true;
        else push(next, x);
    }
    if (!found) push(next, item_name);
    if (length(next) > 0) c.set(CONFIG_NAME, sec_name, list_key, next);
    else c.delete(CONFIG_NAME, sec_name, list_key);
    return !found;
}

function handle_sec_cond_tog(token, chat_id, msg_id, sec_name, cond_name) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    toggle_ref_in_list(c, sec_name, "condition_refs", cond_name);
    c.commit(CONFIG_NAME);
    return view_sec_conds(token, chat_id, msg_id, sec_name);
}

function handle_sec_match_all(token, chat_id, msg_id, sec_name) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let s = c.get_all(CONFIG_NAME, sec_name);
    if (!s) return;
    let cur = section_match_all_enabled(s);
    let target_holder = section_primary_atomic_condition(s) || s;
    let hname = target_holder[".name"] || sec_name;
    if (cur) {
        for (let h in section_own_and_conditions(s)) {
            if (h[".name"]) c.delete(CONFIG_NAME, h[".name"], "match_all");
        }
    } else {
        c.set(CONFIG_NAME, hname, "match_all", "1");
    }
    c.commit(CONFIG_NAME);
    return view_sec_conds(token, chat_id, msg_id, sec_name);
}

function handle_sec_src_tog(token, chat_id, msg_id, sec_name, src_name) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    toggle_ref_in_list(c, sec_name, "outbound_source_refs", src_name);
    c.commit(CONFIG_NAME);
    return view_sec_subs(token, chat_id, msg_id, sec_name);
}

function handle_sec_bal_tog(token, chat_id, msg_id, sec_name, bal_name) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    toggle_ref_in_list(c, sec_name, "balancer_refs", bal_name);
    c.commit(CONFIG_NAME);
    return view_sec_bals(token, chat_id, msg_id, sec_name);
}

function handle_sec_grp_tog(token, chat_id, msg_id, sec_name, member_name) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    toggle_ref_in_list(c, sec_name, "group_members", member_name);
    c.commit(CONFIG_NAME);
    return view_sec_grp(token, chat_id, msg_id, sec_name);
}

function handle_sec_sub_add(token, chat_id, msg_id, sec_name, url) {
    if (!sec_name || !url) {
        set_tg_state(chat_id, { action: "sec_sub_add", sec: sec_name || null });
        return send_message(token, chat_id, "📝 " + t("sub_enter_url"), "HTML");
    }
    url = trim(url);
    if (url == "") {
        send_message(token, chat_id, "❌ " + t("sub_url_empty"));
        return;
    }
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let max_idx = 0;
    let all = c.get_all(CONFIG_NAME);
    for (let sname in all) {
        if (all[sname][".type"] == "subscription_url" || all[sname][".type"] == "outbound_source") {
            let m = match(sname, /^sub_(\d+)$/);
            if (m) {
                let i = int(m[1]);
                if (i > max_idx) max_idx = i;
            }
        }
    }
    let new_sec = "sub_" + (max_idx + 1);
    c.set(CONFIG_NAME, new_sec, "outbound_source");
    c.set(CONFIG_NAME, new_sec, "source_type", "subscription");
    c.set(CONFIG_NAME, new_sec, "enabled", "1");
    c.set(CONFIG_NAME, new_sec, "section", sec_name);
    c.set(CONFIG_NAME, new_sec, "url", url);
    c.set(CONFIG_NAME, new_sec, "label", url);
    if (all[sec_name]) {
        c.add_list(CONFIG_NAME, sec_name, "outbound_source_refs", new_sec);
        let brefs = common.list_option(all[sec_name], "balancer_refs");
        if (length(brefs) > 0 && all[brefs[0]])
            c.add_list(CONFIG_NAME, brefs[0], "source_refs", new_sec);
    }
    c.commit(CONFIG_NAME);
    set_tg_state(chat_id, null);
    send_message(token, chat_id, "✅ " + t("sub_added") + " <code>" + sec_name + "</code>!", "HTML");
    view_sec_subs(token, chat_id, null, sec_name);
}

function handle_sec_sub_del(token, chat_id, msg_id, sec_name, target_or_idx) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let all = c.get_all(CONFIG_NAME);
    let s = all[sec_name];
    let target = null;

    if (type(target_or_idx) == "string" && all[target_or_idx]) {
        target = target_or_idx;
    } else {
        let idx = int(target_or_idx);
        let eff = s ? section_outbound_sources(s) : [];
        if (idx >= 0 && idx < length(eff))
            target = eff[idx][".name"];
    }

    if (!target || !all[target]) {
        send_message(token, chat_id, "❌ " + t("sub_not_found"));
        return view_sec_subs(token, chat_id, null, sec_name);
    }

    if (s) {
        let orefs = common.list_option(s, "outbound_source_refs");
        let next_orefs = [];
        for (let r in orefs) if (r != target) push(next_orefs, r);
        if (length(next_orefs) > 0) c.set(CONFIG_NAME, sec_name, "outbound_source_refs", next_orefs);
        else c.delete(CONFIG_NAME, sec_name, "outbound_source_refs");

        for (let bref in common.list_option(s, "balancer_refs")) {
            let bal = all[bref];
            if (!bal) continue;
            let srefs = common.list_option(bal, "source_refs");
            let next_srefs = [];
            for (let r in srefs) if (r != target) push(next_srefs, r);
            if (length(next_srefs) > 0) c.set(CONFIG_NAME, bref, "source_refs", next_srefs);
            else c.delete(CONFIG_NAME, bref, "source_refs");
        }
    }

    if (all[target][".type"] == "subscription_url" || all[target].section == sec_name) {
        c.delete(CONFIG_NAME, target);
    }
    c.commit(CONFIG_NAME);
    set_tg_state(chat_id, null);
    send_message(token, chat_id, "✅ " + t("sub_removed") + " <code>" + sec_name + "</code>.", "HTML");
    view_sec_subs(token, chat_id, null, sec_name);
}

function handle_lang_set(token, chat_id, msg_id, lang) {
    lang = i18n.resolve_lang(lang);
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    c.set(CONFIG_NAME, "telegram", "language", lang);
    c.commit(CONFIG_NAME);
    t = i18n.bind(lang);
    register_bot_commands(token);
    let lang_label = (lang == "ru") ? "Русский" : "English";
    let text = "✅ <b>" + t("lang_saved") + "</b>\n\n" + t("lang_current", lang_label);
    let keyboard = [[{ text: t("nav_back"), callback_data: "/settings" }]];
    if (msg_id) return edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
    return send_message(token, chat_id, text, "HTML", keyboard);
}

function handle_guest_toggle(token, chat_id, msg_id) {
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let s = object_or_empty(c.get_all(CONFIG_NAME, "guest_mode"));
    let cur = bool_option(s, "enabled", false);
    let nxt = cur ? "0" : "1";
    c.set(CONFIG_NAME, "guest_mode", "enabled", nxt);
    c.commit(CONFIG_NAME);
    command_status(command_from_args(["/usr/bin/tachyon", "reload_firewall"]));
    return view_guest_mode(token, chat_id, msg_id);
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

function handle_toggle_mac(token, chat_id, mac_raw) {
    let mac = normalize_mac(mac_raw);
    if (!mac) {
        send_message(token, chat_id, "❌ " + t("mac_invalid"), "HTML");
        return view_devices(token, chat_id, null);
    }

    let c = uci_core.cursor();
    if (!c) {
        return send_message(token, chat_id, "❌ " + t("mac_firewall_open_failed"), "HTML",
            [[{ text: "⬅️ " + t("nav_menu"), callback_data: "/menu" }]]);
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
            return send_message(token, chat_id, "❌ " + t("mac_block_rule_failed"), "HTML",
                [[{ text: "⬅️ " + t("nav_menu"), callback_data: "/menu" }]]);
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

function handle_qos_toggle(token, chat_id, msg_id) {
    let c = uci_core.cursor(); c.load(CONFIG_NAME);
    let cfg = c.get_all(CONFIG_NAME, "settings") || {};
    let new_val = (cfg.qos_priority_engine == "0") ? "1" : "0";
    c.set(CONFIG_NAME, "settings", "qos_priority_engine", new_val);
    c.commit(CONFIG_NAME);
    system(common.background_command("/usr/bin/tachyon reload_firewall"));
    view_qos(token, chat_id, msg_id);
}

function handle_router_name_set(token, chat_id, msg_id, new_name) {
    t = i18n.bind(settings().language);
    new_name = trim(as_string(new_name || ""));
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    if (!c.get_all(CONFIG_NAME, "telegram"))
        c.set(CONFIG_NAME, "telegram", "telegram");
    if (new_name == "") {
        c.delete(CONFIG_NAME, "telegram", "router_name");
        c.commit(CONFIG_NAME);
        send_message(token, chat_id, "✅ " + t("router_name_cleared"), "HTML");
    } else {
        c.set(CONFIG_NAME, "telegram", "router_name", new_name);
        c.commit(CONFIG_NAME);
        send_message(token, chat_id, "✅ " + t("router_name_saved") + " <code>" + escape_html(new_name) + "</code>", "HTML");
    }
    return view_router_name(token, chat_id, null);
}

function dispatch_command(token, chat_id, text, msg_id) {
    t = i18n.bind(settings().language);
    let cmd = trim(as_string(text));

    // Resolve tokenized callbacks produced by cb_data() for oversized payloads
    if (match(cmd, /^\/cb /)) {
        let cb_tok = trim(substr(cmd, 4));
        let full = cb_map_get(cb_tok);
        if (full == null || full == "") {
            return send_message(token, chat_id,
                "⚠️ " + t("cb_obsolete"), "HTML",
                [[{ text: "⬅️ " + t("nav_menu"), callback_data: "/menu" }]]);
        }
        cmd = trim(full);
    }

    let state = get_tg_state(chat_id);
    
    if (cmd == "/noop") return;
    if (cmd == "/start" || cmd == "/menu") return view_menu(token, chat_id, msg_id);
    if (cmd == "/status") return view_status(token, chat_id, msg_id);
    if (cmd == "/runtime") return view_runtime(token, chat_id, msg_id);
    if (cmd == "/heal" || cmd == "/ai_heal" || cmd == "/ai_doctor") return exec_ai_heal(token, chat_id, msg_id);
    if (cmd == "/reload_tachyon" || cmd == "/restart_tachyon") {
        send_message(token, chat_id, "🔄 <b>" + t("menu_restart") + "...</b>", "HTML");
        command_status(command_from_args(["/usr/bin/tachyon", "reload", "force"]));
        return send_message(token, chat_id, "✅ <b>Tachyon reloaded</b>", "HTML", [
            [{ text: "🏠 " + t("nav_menu"), callback_data: "/menu" }]
        ]);
    }
    if (cmd == "/restore_internet" || cmd == "/restore_native_internet") {
        send_message(token, chat_id, "🚑 <b>" + t("menu_restore_internet") + "...</b>", "HTML");
        command_status(command_from_args(["/usr/bin/tachyon", "restore_native_internet"]));
        return send_message(token, chat_id, "✅ <b>" + t("internet_restored") + "</b>", "HTML", [
            [{ text: "🏠 " + t("nav_menu"), callback_data: "/menu" }]
        ]);
    }
    if (cmd == "/qos") return view_qos(token, chat_id, msg_id);
    if (cmd == "/qos_toggle") return handle_qos_toggle(token, chat_id, msg_id);

    if (cmd == "/speed") return exec_speedtest(token, chat_id, msg_id);
    if (cmd == "/ping") return view_ping(token, chat_id, msg_id);
    if (cmd == "/test") return view_quick_test(token, chat_id, msg_id);
    if (cmd == "/info") return view_system_info(token, chat_id, msg_id);
    if (cmd == "/help") return view_help(token, chat_id, msg_id);
    if (cmd == "/name" || cmd == "/router_name") return view_router_name(token, chat_id, msg_id);
    if (cmd == "/name_prompt") {
        set_tg_state(chat_id, { action: "router_name" });
        return send_message(token, chat_id, t("router_name_prompt"), "HTML");
    }
    if (cmd == "/name_clear") {
        return handle_router_name_set(token, chat_id, msg_id, "");
    }
    let name_match = match(cmd, /^\/(name|router_name)[ \t]+(.+)$/);
    if (name_match) {
        return handle_router_name_set(token, chat_id, msg_id, trim(name_match[2]));
    }
    if (cmd == "/lang" || cmd == "/language") return view_language(token, chat_id, msg_id);
    let lang_match = match(cmd, /^\/(lang_set|lang|language)[ \t]+([a-zA-Z0-9_-]+)/);
    if (lang_match) {
        let lang = lc(trim(lang_match[2]));
        return handle_lang_set(token, chat_id, msg_id, lang);
    }
    if (cmd == "/guest") return view_guest_mode(token, chat_id, msg_id);
    if (cmd == "/guest_toggle") return handle_guest_toggle(token, chat_id, msg_id);

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
            "⏰ " + t("quiet_enter_hour") + " " + (which == "start" ? t("quiet_start_word") : t("quiet_end_word")) +
            " тихих часов (0–23):\n\n<i>Отправьте /cancel для отмены</i>", "HTML");
    }
    
    if (cmd == "/outbounds" || cmd == "/server" || cmd == "/servers") return view_outbounds(token, chat_id, msg_id);
    if (match(cmd, /^\/(outbounds|server|servers) /)) {
        let parts = split(cmd, " ");
        let rest = slice(parts, 1);
        // `/outbounds <page> <group>`; a bare `/outbounds <group>` from an older
        // message still works, and a group name may itself start with digits.
        let page = 0;
        if (length(rest) > 1 && match(trim(rest[0]), /^[0-9]+$/) != null) {
            page = int(trim(rest[0]));
            rest = slice(rest, 1);
        }
        let grp = trim(join(" ", rest));
        return view_outbounds(token, chat_id, msg_id, grp, page);
    }

    if (cmd == "/fptn_token" || cmd == "/fptn") {
        set_tg_state(chat_id, { action: "fptn_token" });
        return send_message(token, chat_id,
            "🔑 <b>" + t("fptn_token_title") + "</b>\n\n" +
            t("fptn_token_prompt") + "\n\n<i>Отправьте /cancel для отмены</i>", "HTML");
    }
    if (match(cmd, /^\/(fptn_token|fptn)[ \t]+/)) {
        let raw_token = trim(replace(cmd, /^\/(fptn_token|fptn)[ \t]+/, ""));
        let all_sections = api.get_sections();
        let target_sec = null;
        for (let i = 0; i < length(all_sections); i++) {
            let s = all_sections[i];
            if (s[".name"] == raw_token || s.name == raw_token) {
                target_sec = raw_token;
                break;
            }
        }
        if (target_sec) {
            set_tg_state(chat_id, { action: "fptn_token", sec: target_sec });
            return send_message(token, chat_id,
                "🔑 <b>" + t("fptn_token_title") + " (" + escape_html(target_sec) + ")</b>\n\n" +
                t("fptn_token_prompt") + "\n\n<i>Отправьте /cancel для отмены</i>", "HTML");
        }
        return handle_fptn_token_update(token, chat_id, raw_token, null);
    }
    
    if (cmd == "/sections" || cmd == "/rules") return view_sections(token, chat_id, msg_id);
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
            send_message(token, chat_id, "❌ <b>" + t("err_unknown_component") + "</b> <code>" + escape_html(comp) + "</code>", "HTML", [[{text:"⬅️ " + t("nav_menu"), callback_data:"/menu"}]]);
            return;
        }
        let comp_title = rendering.component_display_title(comp);
        if (msg_id) edit_message(token, chat_id, msg_id, "⏳ <b>" + t("update_component_title") + " " + escape_html(comp_title) + "...</b>\n" + t("update_bg_hint"), "HTML", [[{text:"⬅️ " + t("nav_menu"), callback_data:"/menu"}]]);
        else send_message(token, chat_id, "⏳ <b>" + t("update_component_title") + " " + escape_html(comp_title) + "...</b>\n" + t("update_bg_hint"), "HTML", [[{text:"⬅️ " + t("nav_menu"), callback_data:"/menu"}]]);
        command_status(command_from_args(["/usr/bin/tachyon", "component_action_async", comp, "install"]));
        return;
    }
    
    if (match(cmd, /^\/admin_add /)) {
        let fwd_id = trim(substr(cmd, 11));
        if (!match(fwd_id, /^-?[0-9]+$/)) {
            send_message(token, chat_id, "❌ " + t("admin_invalid_chat_id"), "HTML");
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
            if (msg_id) edit_message(token, chat_id, msg_id, "✅ " + t("admin_user_added") + " `" + fwd_id + "`", "Markdown", [[{text:"⬅️ " + t("nav_menu"), callback_data:"/menu"}]]);
            else send_message(token, chat_id, "✅ " + t("admin_user_added") + " `" + fwd_id + "`", "Markdown", [[{text:"⬅️ " + t("nav_menu"), callback_data:"/menu"}]]);
        } else {
            if (msg_id) edit_message(token, chat_id, msg_id, "ℹ️ " + t("admin_user_already") + " `" + fwd_id + "`", "Markdown", [[{text:"⬅️ " + t("nav_menu"), callback_data:"/menu"}]]);
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
        return send_message(token, chat_id, t("sec_enter_name"), "HTML");
    }
    if (match(cmd, /^\/sec_rename /)) {
        let sec = trim(substr(cmd, 12));
        set_tg_state(chat_id, { action: "sec_rename", sec: sec });
        return send_message(token, chat_id, t("sec_enter_label") + " <code>" + sec + "</code>:\n\n<i>Отправьте /cancel для отмены</i>", "HTML");
    }
    if (match(cmd, /^\/sec_target /)) {
        let sec = trim(substr(cmd, 12));
        set_tg_state(chat_id, { action: "sec_target", sec: sec });
        return send_message(token, chat_id, t("sec_enter_target") + " <code>" + sec + "</code> (например, <code>main-out</code> или <code>direct-out</code>):\n\n<i>Отправьте /cancel для отмены</i>", "HTML");
    }
    if (match(cmd, /^\/sec_action /)) {
        let parts = split(trim(substr(cmd, 12)), " ");
        return handle_sec_action(token, chat_id, msg_id, parts[0], parts[1] || "");
    }
    if (match(cmd, /^\/sec_dns_edit /)) {
        let sec = trim(substr(cmd, 14));
        set_tg_state(chat_id, { action: "sec_dns_edit", sec: sec });
        return send_message(token, chat_id, t("sec_dns_prompt"), "HTML");
    }
    if (match(cmd, /^\/sec_conds /)) {
        let sec = trim(substr(cmd, 11));
        return view_sec_conds(token, chat_id, msg_id, sec);
    }
    if (match(cmd, /^\/sec_cond_tog /)) {
        let parts = split(trim(substr(cmd, 14)), " ");
        if (length(parts) >= 2) return handle_sec_cond_tog(token, chat_id, msg_id, parts[0], parts[1]);
    }
    if (match(cmd, /^\/sec_cond_new /)) {
        let sec = trim(substr(cmd, 14));
        set_tg_state(chat_id, { action: "sec_cond_new", sec: sec });
        return send_message(token, chat_id, t("sec_cond_enter_name"), "HTML");
    }
    if (match(cmd, /^\/sec_match_all /)) {
        let sec = trim(substr(cmd, 15));
        return handle_sec_match_all(token, chat_id, msg_id, sec);
    }
    if (match(cmd, /^\/sec_bals /)) {
        let sec = trim(substr(cmd, 10));
        return view_sec_bals(token, chat_id, msg_id, sec);
    }
    if (match(cmd, /^\/sec_bal_tog /)) {
        let parts = split(trim(substr(cmd, 13)), " ");
        if (length(parts) >= 2) return handle_sec_bal_tog(token, chat_id, msg_id, parts[0], parts[1]);
    }
    if (match(cmd, /^\/sec_grp /)) {
        let sec = trim(substr(cmd, 9));
        return view_sec_grp(token, chat_id, msg_id, sec);
    }
    if (match(cmd, /^\/sec_grp_tog /)) {
        let parts = split(trim(substr(cmd, 13)), " ");
        if (length(parts) >= 2) return handle_sec_grp_tog(token, chat_id, msg_id, parts[0], parts[1]);
    }
    if (match(cmd, /^\/sec_src_tog /)) {
        let parts = split(trim(substr(cmd, 13)), " ");
        if (length(parts) >= 2) return handle_sec_src_tog(token, chat_id, msg_id, parts[0], parts[1]);
    }
    if (match(cmd, /^\/sec_delete /)) {
        let sec = trim(substr(cmd, 12));
        let c = uci_core.cursor();
        c.load(CONFIG_NAME);
        let s = c.get_all(CONFIG_NAME, sec);
        if (!s) {
            send_message(token, chat_id, "❌ " + t("sec_not_found") + " <code>" + sec + "</code>", "HTML");
            return view_sections(token, chat_id, null);
        }
        get_connections().cascade_delete_section(c, CONFIG_NAME, sec);
        c.delete(CONFIG_NAME, sec);
        c.commit(CONFIG_NAME);
        send_message(token, chat_id, "✅ " + t("sec_deleted") + " <code>" + sec + "</code>", "HTML");
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
            return send_message(token, chat_id, t("sec_add_items_prompt"), "HTML");
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

    // Section subscription commands
    if (match(cmd, /^\/sec_subs /)) {
        let sec = trim(substr(cmd, 11));
        return view_sec_subs(token, chat_id, msg_id, sec);
    }
    if (match(cmd, /^\/sec_sub_add /)) {
        let parts = split(trim(substr(cmd, 13)), " ");
        if (length(parts) >= 2) {
            let sec = parts[0];
            let url = join(" ", slice(parts, 1));
            return handle_sec_sub_add(token, chat_id, msg_id, sec, url);
        } else if (length(parts) == 1 && parts[0] != "") {
            return handle_sec_sub_add(token, chat_id, msg_id, parts[0], null);
        }
    }
    if (cmd == "/sec_sub_add") {
        set_tg_state(chat_id, { action: "sec_sub_add" });
        return send_message(token, chat_id, t("sec_sub_add_prompt"), "HTML");
    }
    if (match(cmd, /^\/sec_sub_del /)) {
        let parts = split(trim(substr(cmd, 13)), " ");
        if (length(parts) == 2) return handle_sec_sub_del(token, chat_id, msg_id, parts[0], parts[1]);
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
    if (match(cmd, /^\/set_del /)) {
        let parts = split(trim(substr(cmd, 9)), " ");
        if (length(parts) >= 2) return handle_set_del(token, chat_id, msg_id, parts[0], parts[1]);
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
            return send_message(token, chat_id, t("sec_enter_value") + " <code>" + parts[2] + "</code>:\n\n<i>Отправьте /cancel для отмены</i>", "HTML");
        }
    }
    if (match(cmd, /^\/set_arr_add /)) {
        let parts = split(trim(substr(cmd, 13)), " ");
        if (length(parts) >= 3) {
            set_tg_state(chat_id, { action: "set_arr_add", stype: parts[0], sname: parts[1], key: parts[2] });
            return send_message(token, chat_id, t("sec_add_list_prompt"), "HTML");
        }
    }

    if (cmd == "/dns_presets" || cmd == "/dns_servers") {
        let dp = get_dns_presets();
        let c = uci_core.cursor(); c.load(CONFIG_NAME);
        let s = c.get_all(CONFIG_NAME, "settings");
        let dns_type = option(s, "dns_type", "doh");
        let text = dp.format_presets_list(dns_type);
        let presets = dp.get_presets(dns_type);
        let keyboard = [];
        for (let i = 0; i < length(presets); i++) {
            let p = presets[i];
            push(keyboard, [{ text: p.country + " " + p.name, callback_data: "/dns_apply " + as_string(i) }]);
        }
        push(keyboard, [{ text: t("dns_all_protocols"), callback_data: "/dns_protocols" }]);
        push(keyboard, [{ text: "⬅️ " + t("nav_back"), callback_data: "/settings" }]);
        if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
        else send_message(token, chat_id, text, "HTML", keyboard);
        return;
    }
    if (match(cmd, /^\/dns_apply /)) {
        let dp = get_dns_presets();
        let idx = int(trim(substr(cmd, 11)));
        let c = uci_core.cursor(); c.load(CONFIG_NAME);
        let s = c.get_all(CONFIG_NAME, "settings");
        let dns_type = option(s, "dns_type", "doh");
        let presets = dp.get_presets(dns_type);
        if (idx >= 0 && idx < length(presets)) {
            let preset = presets[idx];
            let servers = dp.get_preset_servers(preset);
            c.delete(CONFIG_NAME, "settings", "dns_server");
            for (let srv in servers) c.add_list(CONFIG_NAME, "settings", "dns_server", srv);
            c.commit(CONFIG_NAME);
            send_message(token, chat_id, "✅ <b>" + t("dns_servers_applied") + "</b>\n" + dp.format_preset(preset, idx) + "\n\nТип: <code>" + dns_type + "</code>\n\n⚠️ " + t("dns_restart_hint"), "HTML", [[{text: "🔄 Перезапустить", callback_data: "/confirm_restart"}, {text: "⬅️ " + t("nav_back"), callback_data: "/dns_presets"}]]);
        }
        return;
    }
    if (cmd == "/bootstrap_presets") {
        let dp = get_dns_presets();
        let text = dp.format_bootstrap_presets_list();
        let presets = dp.get_bootstrap_presets();
        let keyboard = [];
        for (let i = 0; i < length(presets); i++) {
            let p = presets[i];
            push(keyboard, [{ text: p.country + " " + p.name, callback_data: "/bootstrap_apply " + as_string(i) }]);
        }
        push(keyboard, [{ text: "⬅️ " + t("nav_back"), callback_data: "/settings" }]);
        if (msg_id) edit_message(token, chat_id, msg_id, text, "HTML", keyboard);
        else send_message(token, chat_id, text, "HTML", keyboard);
        return;
    }
    if (match(cmd, /^\/bootstrap_apply /)) {
        let dp = get_dns_presets();
        let idx = int(trim(substr(cmd, 17)));
        let presets = dp.get_bootstrap_presets();
        if (idx >= 0 && idx < length(presets)) {
            let preset = presets[idx];
            let servers = dp.get_preset_servers(preset);
            let c = uci_core.cursor(); c.load(CONFIG_NAME);
            c.delete(CONFIG_NAME, "settings", "bootstrap_dns_server");
            for (let srv in servers) c.add_list(CONFIG_NAME, "settings", "bootstrap_dns_server", srv);
            c.commit(CONFIG_NAME);
            send_message(token, chat_id, "✅ <b>" + t("dns_bootstrap_applied") + "</b>\n" + dp.format_preset(preset, idx) + "\n\n⚠️ " + t("dns_restart_hint"), "HTML", [[{text: "🔄 Перезапустить", callback_data: "/confirm_restart"}, {text: "⬅️ " + t("nav_back"), callback_data: "/bootstrap_presets"}]]);
        }
        return;
    }
    if (cmd == "/dns_protocols") {
        let dp = get_dns_presets();
        let text = dp.format_protocol_info();
        let keyboard = [[{ text: "⬅️ " + t("nav_back"), callback_data: "/dns_presets" }]];
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

return {
    handle_set_tog,
    handle_set_del,
    handle_fptn_token_update,
    handle_switch,
    handle_sec_toggle,
    handle_sec_action,
    handle_sec_cond_tog,
    handle_sec_match_all,
    handle_sec_src_tog,
    handle_sec_bal_tog,
    handle_sec_grp_tog,
    handle_sec_del_it,
    handle_sec_clear,
    apply_confirmed_restart,
    apply_backup_restore,
    handle_sec_sub_add,
    handle_sec_sub_del,
    handle_router_name_set,
    handle_lang_set,
    handle_guest_toggle,
    handle_qh_toggle,
    handle_toggle_mac,
    handle_qos_toggle,
    dispatch_command
};
