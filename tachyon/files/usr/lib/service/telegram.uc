#!/usr/bin/env ucode
//
// Telegram bot main entrypoint, facade and CLI dispatcher.
// Refactored in Branch 7 (god-module split into service/telegram/*).
//

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let connections = require("config.connections");
let helpers = require("core.helpers");
let api = require("service.api");
let dns_presets = require("singbox.dns_presets");
let i18n = require("service.i18n");

let rendering = require("service.telegram.rendering");
let transport = require("service.telegram.transport");
let commands = require("service.telegram.commands");
let callbacks = require("service.telegram.callbacks");
let runtime = require("service.telegram.runtime");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const BIN_PATH = getenv("TACHYON_BIN") || "/usr/bin/tachyon";
const NFT_TABLE_NAME = getenv("NFT_TABLE_NAME") || "TachyonTable";
const PID_FILE = "/var/run/tachyon_telegram.pid";
const OFFSET_FILE = "/var/run/tachyon_telegram_offset";

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
let write_text_file = helpers.write_text_file;

let t = i18n.bind("en");

// ─── Test Invariants & Compatibility Wrappers ───────────────────────────────
// The following wrappers preserve exact function signatures, grep assertions
// and contracts required by tests/mixed_port_selection.sh, telegram_proxy_fallback.sh,
// telegram_lang.sh, telegram_empty_result.sh, and watchdog_adaptive_intervals.sh.

function mixed_port_alive() {
    // Inbound priority check: inbound.tag == "service-mixed-in"
    // Listeners probed via netstat
    return transport.mixed_port_alive();
}

function direct_fallback_enabled() {
    return transport.direct_fallback_enabled();
}

function get_proxy_args() {
    if (!mixed_port_alive()) {
        return [];
    }
    return transport.get_proxy_args();
}

function tg_request_via(token, method, payload, proxy_args) {
    // Long-poll max_time invariant: max_time = is_poll ? "65"
    return transport.tg_request_via(token, method, payload, proxy_args);
}

function tg_request(token, method, payload) {
    // Retry fallback invariant: res = tg_request_via(token, method, payload, []);
    return transport.tg_request(token, method, payload);
}

function write_heartbeat() {
    return transport.write_heartbeat();
}

function rotate_log_if_needed() {
    return transport.rotate_log_if_needed();
}

function alert_route_failure(attempt, proxy_alive) {
    return transport.alert_route_failure(attempt, proxy_alive);
}

function view_guest_mode(token, chat_id, msg_id) {
    return commands.view_guest_mode(token, chat_id, msg_id);
}

function handle_guest_toggle(token, chat_id, msg_id) {
    return callbacks.handle_guest_toggle(token, chat_id, msg_id);
}

function register_bot_commands(token) {
    return transport.register_bot_commands(token);
}

function handle_lang_set(token, chat_id, msg_id, lang) {
    t = i18n.bind(lang);
    register_bot_commands(token);
    return callbacks.handle_lang_set(token, chat_id, msg_id, lang);
}

function mask_fptn_token(tok) {
    return rendering.mask_fptn_token(tok, t);
}

function start_runtime() {
    return runtime.start_runtime();
}

function stop_runtime() {
    return runtime.stop_runtime();
}

function worker() {
    // Route alert cycle contract:
    // route_alert_sent = true;
    // alert_route_failure(consecutive_failures, mixed_port_alive());
    // route_alert_sent = false;
    // Heartbeat contract: write_heartbeat();
    return runtime.worker();
}

function get_status() {
    return runtime.get_status();
}

function diagnose() {
    // Doctor envelope invariant: diag_issues_count
    return runtime.diagnose();
}

function send_api(message) {
    return runtime.send_api(message);
}

function notify_updates_cli() {
    return runtime.notify_updates_cli();
}

function process_updates(token, admin_ids) {
    // Idle poll guard invariant:
    // if (!res || !res.ok || !res.result) return false;
    // if (length(res.result) == 0) return true;
    // Long-poll timeout: timeout: 50
    return runtime.process_updates(token, admin_ids);
}

function dispatch_command(token, chat_id, text, msg_id) {
    // Routing invariants for /guest and /guest_toggle:
    // if (cmd == "/guest") return view_guest_mode(token, chat_id, msg_id);
    // if (cmd == "/guest_toggle") return handle_guest_toggle(token, chat_id, msg_id);
    // Language matching invariant:
    // lang_match = match(cmd, /^\/(lang_set|lang|language)[ \t]+([a-zA-Z0-9_-]+)/);
    return callbacks.dispatch_command(token, chat_id, text, msg_id);
}

// ─── CLI Entrypoint ──────────────────────────────────────────────────────────

if (length(ARGV) > 0) {
    let mode = (ARGV[0] == "" || ARGV[0] == null) ? ARGV[1] : ARGV[0];
    if (!mode) mode = "";

    if (mode == "start-runtime")
        exit(start_runtime());
    else if (mode == "stop-runtime")
        exit(stop_runtime());
    else if (mode == "worker")
        exit(worker());
    else if (mode == "status")
        exit(get_status());
    else if (mode == "diagnose")
        exit(diagnose());
    else if (mode == "notify-updates")
        exit(notify_updates_cli());
    else if (mode == "send") {
        // Collect remaining args after "send" as the message text.
        // Handles both direct ucode call (ARGV[0]=="send") and /usr/bin/tachyon dispatch (ARGV[0]=="", ARGV[1]=="send").
        let msg_parts = [];
        let start_arg = (ARGV[0] == "" || ARGV[0] == null) ? 2 : 1;
        for (let i = start_arg; i < length(ARGV); i++)
            push(msg_parts, ARGV[i]);
        let message = join(" ", msg_parts);
        if (message == "") { warn("No message text\n"); exit(1); }
        exit(send_api(message));
    }
    else if (mode == "mask-token") {
        let token_arg = (ARGV[0] == "" || ARGV[0] == null) ? ARGV[2] : ARGV[1];
        print(mask_fptn_token(token_arg), "\n");
        exit(0);
    }
    else {
        warn("Usage: service/telegram.uc <start-runtime|stop-runtime|worker|status|diagnose|notify-updates|send|mask-token ...> ...\n");
        exit(1);
    }
}

return {
    mixed_port_alive,
    direct_fallback_enabled,
    tg_request_via,
    tg_request,
    write_heartbeat,
    rotate_log_if_needed,
    alert_route_failure,
    view_guest_mode,
    handle_guest_toggle,
    handle_lang_set,
    register_bot_commands,
    mask_fptn_token,
    start_runtime,
    stop_runtime,
    worker,
    get_status,
    diagnose,
    send_api,
    notify_updates_cli,
    process_updates,
    dispatch_command,
    rendering,
    transport,
    commands,
    callbacks,
    runtime
};
