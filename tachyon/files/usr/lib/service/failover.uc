#!/usr/bin/env ucode

// Cross-section proxy failover: probe every candidate section through the
// Clash API delay endpoint; when the active section misses the failure
// threshold in a row, switch the tachyon-failover selector to a healthy one,
// persist the choice and notify Telegram.
//
// The runtime switch only works when sing-box was generated with
// section_failover_enabled=1 (the catch-all route then points at the
// tachyon-failover selector group).
//
// NOTE: ucode does not hoist function declarations - keep callees above
// their first caller.

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let connections = require("config.connections");

let as_string = common.as_string;
let object_or_empty = common.object_or_empty;
let option = common.option;
let int_option = common.int_option;
let bool_option = common.bool_option;
let shell_quote = common.shell_quote;
let command_from_args = common.command_from_args;
let command_status = common.command_status;
let command_success_from_args = common.command_success_from_args;
let command_output_from_args = common.command_output_from_args;
let write_json = common.write_json;
let write_json_file = common.write_json_file;

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const TACHYON_BIN = getenv("TACHYON_BIN") || "/usr/bin/tachyon";
const STATE_FILE = getenv("TACHYON_FAILOVER_STATE_FILE") || "/etc/tachyon/failover_section";
const STREAK_FILE = getenv("TACHYON_FAILOVER_STREAK_FILE") || "/var/run/tachyon/failover_streak";
const SECTION_FAIL_STATE_FILE = getenv("TACHYON_SECTION_FAIL_STATE_FILE") || "/var/run/tachyon/section-fail-state.json";
const PROBE_TIMEOUT_MS = getenv("TACHYON_FAILOVER_PROBE_TIMEOUT") || "3000";

const FAILOVER_GROUP_TAG = "tachyon-failover";

function log_message(message, level) {
    level = as_string(level || "info");
    command_success_from_args([ "logger", "-t", "tachyon", "[failover] [" + level + "] " + as_string(message) ]);
}

function settings() {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
}

function enabled() {
    return bool_option(settings(), "section_failover_enabled", false);
}

function threshold() {
    let value = int_option(settings(), "section_failover_threshold", 3);
    return value > 0 ? value : 3;
}

// Same ordering semantics as the generator: UCI order of enabled sections.
// Prioritize remote proxy candidates when present.
function candidates() {
    let all = [];
    let proxies = [];
    for (let section in uci_core.section_objects(CONFIG_NAME, "section")) {
        if (!bool_option(section, "enabled", true))
            continue;
        let action = option(section, "action", "");
        if (connections.is_remote_proxy_action(action)) {
            push(proxies, as_string(section[".name"]));
            push(all, as_string(section[".name"]));
        } else if (action == "byedpi" || action == "zapret" || action == "zapret2" ||
            action == "wdtt" || action == "olcrtc") {
            push(all, as_string(section[".name"]));
        }
    }
    return length(proxies) > 0 ? proxies : all;
}

function read_active(candidates_list) {
    let raw = "";
    try {
        raw = trim(as_string(fs.readfile(STATE_FILE)) || "");
    } catch (e) {
        raw = "";
    }
    if (raw != "") {
        for (let name in candidates_list)
            if (as_string(name) == raw)
                return raw;
    }
    return length(candidates_list) > 0 ? as_string(candidates_list[0]) : "";
}

function write_active(name) {
    fs.unlink(STATE_FILE);
    if (!fs.writefile(STATE_FILE, as_string(name) + "\n"))
        log_message("failed to persist failover state", "warn");
}

function read_streak() {
    let raw = trim(as_string(fs.readfile(STREAK_FILE)) || "");
    let value = int(raw);
    return value > 0 ? value : 0;
}

function write_streak(value) {
    fs.unlink(STREAK_FILE);
    fs.writefile(STREAK_FILE, as_string(value) + "\n");
}

function clash_delay_ok(tag) {
    let out = trim(command_output_from_args([ TACHYON_BIN, "clash_api", "get_proxy_latency", tag, PROBE_TIMEOUT_MS ]) || "");
    if (out == "")
        return false;
    let parsed = null;
    try {
        parsed = json(out);
    } catch (e) {
        return false;
    }
    return object_or_empty(parsed)["delay"] != null;
}

function switch_group(section_name, outbound_name) {
    let out = trim(command_output_from_args([ TACHYON_BIN, "clash_api", "set_group_proxy", FAILOVER_GROUP_TAG, outbound_name ]) || "");
    // set_group_proxy prints a JSON error object on failure.
    if (index(out, '"error"') >= 0) {
        log_message("runtime switch failed: " + out, "warn");
        return false;
    }
    return true;
}

function send_notification(message) {
    let tcfg = object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
    if (as_string(tcfg.enabled || "0") != "1" || !tcfg.bot_token || !tcfg.admin_ids)
        return;
    system(common.background_command(TACHYON_BIN + " telegram send " + shell_quote(message)));
}

function read_section_fail_state() {
    let raw = "";
    try {
        raw = trim(as_string(fs.readfile(SECTION_FAIL_STATE_FILE)) || "");
    } catch (e) {
        raw = "";
    }
    if (raw == "")
        return {};
    let parsed = null;
    try {
        parsed = json(raw);
    } catch (e) {
        parsed = null;
    }
    return type(parsed) == "object" ? parsed : {};
}

function write_section_fail_state(state_map) {
    let dir = replace(as_string(SECTION_FAIL_STATE_FILE), /\/[^\/]+$/, "");
    if (dir != "" && dir != SECTION_FAIL_STATE_FILE)
        command_success_from_args([ "mkdir", "-p", dir ]);
    write_json_file(SECTION_FAIL_STATE_FILE, object_or_empty(state_map));
}

function check_section_fail_policies() {
    let prev_map = read_section_fail_state();
    let next_map = {};
    let has_policies = false;
    let state_changed = false;
    let max_streak = threshold();

    for (let section in uci_core.section_objects(CONFIG_NAME, "section")) {
        let name = as_string(section[".name"] || "");
        if (name == "" || !bool_option(section, "enabled", true))
            continue;
        let policy = lc(trim(option(section, "fail_policy", "keep")));
        if (policy != "block" && policy != "direct")
            continue;

        has_policies = true;
        let prev = object_or_empty(prev_map[name]);
        let prev_failed = prev.failed == true || as_string(prev.failed || "") == "1";
        let prev_streak = int(prev.streak || 0);
        if (prev_streak < 0)
            prev_streak = 0;

        if (clash_delay_ok(name + "-out")) {
            next_map[name] = {
                streak: 0,
                failed: false,
                policy: policy,
                updated_at: time()
            };
            if (prev_failed) {
                state_changed = true;
                log_message("section " + name + " recovered from fail_policy=" + policy, "info");
                send_notification("✅ *Fail Policy*: секция `" + name + "` восстановилась (политика `" + policy + "` снята).");
            }
        } else {
            let streak = prev_streak + 1;
            let failed = prev_failed || streak >= max_streak;
            next_map[name] = {
                streak: streak,
                failed: failed,
                policy: policy,
                updated_at: time()
            };
            if (!prev_failed && failed) {
                state_changed = true;
                log_message("section " + name + " entered fail_policy=" + policy + " after " + as_string(streak) + " failed probes", "warn");
                send_notification("⚠️ *Fail Policy*: секция `" + name + "` недоступна, применена политика `" + policy + "`.");
            }
        }
    }

    for (let old_name in keys(prev_map)) {
        if (next_map[old_name] == null) {
            let old_entry = object_or_empty(prev_map[old_name]);
            if (old_entry.failed == true || as_string(old_entry.failed || "") == "1")
                state_changed = true;
        }
    }

    if (has_policies || length(keys(prev_map)) > 0)
        write_section_fail_state(next_map);

    if (state_changed && getenv("TACHYON_FAILOVER_SKIP_RELOAD") != "1") {
        command_success_from_args([ TACHYON_BIN, "reload" ]);
    }
}

function check() {
    check_section_fail_policies();

    if (!enabled())
        return 0;
    let list = candidates();
    if (length(list) < 2)
        return 0;

    let active = read_active(list);
    if (active == "")
        return 0;

    if (clash_delay_ok(active + "-out")) {
        write_streak(0);
        return 0;
    }

    let streak = read_streak() + 1;
    if (streak < threshold()) {
        write_streak(streak);
        log_message(active + " failed " + as_string(streak) + "/" + as_string(threshold()), "debug");
        return 0;
    }
    write_streak(0);

    for (let name in list) {
        name = as_string(name);
        if (name == active)
            continue;
        if (!clash_delay_ok(name + "-out"))
            continue;
        write_active(name);
        if (!switch_group(name, name + "-out"))
            log_message("switched state to " + name + ", but live group update failed; will apply on next reload", "warn");
        log_message("active section switched: " + active + " -> " + name, "info");
        send_notification("🔀 *Failover*: секция `" + active + "` недоступна, переключаюсь на `" + name + "`.");
        return 0;
    }

    log_message("active section failed and no healthy backup found", "warn");
    return 0;
}

function status_json() {
    let list = candidates();
    write_json({
        enabled: enabled(),
        threshold: threshold(),
        candidates: list,
        active: read_active(list),
        streak: read_streak(),
        section_fail_policies: read_section_fail_state()
    });
}

let mode = ARGV[0] || "";

if (mode == "check")
    exit(check());
else if (mode == "status")
    status_json();
else {
    warn("Usage: service/failover.uc <check|status>\n");
    exit(1);
}
