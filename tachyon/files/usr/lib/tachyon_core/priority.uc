#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let reachability_guard = require("diagnostics.reachability_guard");

let as_string = common.as_string;
let read_json_file = common.read_json_file;
let write_json = common.write_json;
let array_or_empty = common.array_or_empty;
let object_or_empty = common.object_or_empty;
let shell_quote = common.shell_quote;
let command_from_args = common.command_from_args;
let command_output = common.command_output;
let command_output_from_args = common.command_output_from_args;
let command_status = common.command_status;
let command_success_from_args = common.command_success_from_args;
let remove_file = common.remove_file;

const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const RUNTIME_STATE_DIR = getenv("TACHYON_RUNTIME_STATE_DIR") || "/var/run/tachyon";
const SECTION_CACHE_DIR = getenv("TACHYON_SECTION_CACHE_DIR") || RUNTIME_STATE_DIR + "/section-cache";
const PRIORITY_PID_FILE = getenv("TACHYON_PRIORITY_PID_FILE") || RUNTIME_STATE_DIR + "/priority.pid";
const PRIORITY_UC = getenv("TACHYON_PRIORITY_UC") || LIB_DIR + "/tachyon_core/priority.uc";
const DIAGNOSTICS_UC = getenv("TACHYON_DIAGNOSTICS_UC") || LIB_DIR + "/diagnostics/runtime.uc";

let ensure_dir = common.ensure_dir;
let file_first_line = common.file_first_line;

function log_message(message, level) {
    level = as_string(level || "info");
    command_success_from_args([ "logger", "-t", "tachyon", "[" + level + "] priority: " + as_string(message) ]);
}

function now_seconds() {
    return int(clock()[0]);
}

function duration_to_milliseconds(value, fallback_ms) {
    let rest = as_string(value);
    if (rest == "")
        return fallback_ms;

    let total = 0.0;
    let multipliers = {
        ns: 0.000001,
        us: 0.001,
        ms: 1,
        s: 1000,
        m: 60000,
        h: 3600000,
        d: 86400000
    };

    while (rest != "") {
        let matched = match(rest, /^([0-9]+(\.[0-9]+)?)(ns|us|ms|s|m|h|d)/);
        if (!matched)
            return fallback_ms;

        let token = as_string(matched[0]);
        total += (matched[1] * 1) * multipliers[matched[3]];
        rest = substr(rest, length(token));
    }

    return total <= 0 ? fallback_ms : int(total + 0.5);
}

function duration_to_seconds(value, fallback_seconds) {
    let ms = duration_to_milliseconds(value, fallback_seconds * 1000);
    let seconds = int((ms + 999) / 1000);
    return seconds > 0 ? seconds : fallback_seconds;
}

function bool_value(value, fallback) {
    if (value == null || value == "")
        return !!fallback;
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function normalize_group(group, tag_name) {
    group = object_or_empty(group);
    let levels = [];
    for (let level in array_or_empty(group.levels)) {
        let outbounds = [];
        for (let outbound in array_or_empty(level.outbounds)) {
            outbound = as_string(outbound);
            if (outbound != "")
                push(outbounds, outbound);
        }
        if (length(outbounds) > 0) {
            push(levels, {
                id: as_string(level.id || ""),
                displayName: as_string(level.displayName || level.name || ""),
                order: int(level.order || 0),
                outbounds
            });
        }
    }

    return {
        id: as_string(group.id || ""),
        tag: as_string(group.tag || tag_name),
        section: as_string(group.section || ""),
        displayName: as_string(group.displayName || group.name || tag_name),
        health_url: as_string(group.health_url || "https://www.gstatic.com/generate_204"),
        active_check_interval: as_string(group.active_check_interval || "5s"),
        check_timeout: as_string(group.check_timeout || "2s"),
        recovery_check_interval: as_string(group.recovery_check_interval || "15s"),
        pick_fastest: bool_value(group.pick_fastest, false),
        switch_to_faster_same_priority: bool_value(group.switch_to_faster_same_priority, false),
        fastest_check_interval: as_string(group.fastest_check_interval || "3m"),
        levels
    };
}

function section_cache_files() {
    let result = [];
    let dir = fs.opendir(SECTION_CACHE_DIR);
    if (!dir)
        return result;
    let entry;
    while ((entry = dir.read()) != null) {
        if (substr(entry, -5) == ".json")
            push(result, SECTION_CACHE_DIR + "/" + entry);
    }
    dir.close();
    return sort(result);
}

function priority_groups_from_cache() {
    let result = [];
    for (let path in section_cache_files()) {
        let cache = object_or_empty(read_json_file(path));
        for (let tag_name, group in object_or_empty(cache.priorityGroups)) {
            let normalized = normalize_group(group, tag_name);
            if (normalized.tag != "" && length(normalized.levels) > 0)
                push(result, normalized);
        }
    }
    return result;
}

let cached_clash_cfg_mtime = -1;
let cached_clash_base_url = "http://127.0.0.1:9090";
let cached_clash_secret = "";

function priority_clash_info() {
    let cfg_path = "/etc/tachyon-core/config.json";
    let st = fs.stat(cfg_path);
    let mtime = st ? int(st.mtime || 0) : 0;
    if (mtime != cached_clash_cfg_mtime) {
        cached_clash_cfg_mtime = mtime;
        let host = "127.0.0.1:9090";
        let secret = "";
        let data = st ? fs.readfile(cfg_path) : null;
        if (data) {
            try {
                let sb_cfg = json(data);
                let ext = sb_cfg?.experimental?.clash_api?.external_controller;
                if (ext) {
                    let parts = split(as_string(ext), ":");
                    let ip = length(parts) > 1 ? parts[0] : "";
                    let port = length(parts) > 1 ? parts[length(parts) - 1] : "9090";
                    host = (ip == "0.0.0.0" || ip == "") ? ("127.0.0.1:" + port) : as_string(ext);
                }
                if (sb_cfg?.experimental?.clash_api?.secret)
                    secret = as_string(sb_cfg.experimental.clash_api.secret);
            } catch (e) {}
        }
        cached_clash_base_url = "http://" + host;
        cached_clash_secret = secret;
    }
    return { base_url: cached_clash_base_url, secret: cached_clash_secret };
}

function urlencode_segment(value) {
    value = as_string(value);
    let out = [];
    let len = length(value);
    for (let i = 0; i < len; i++) {
        let ch = substr(value, i, 1);
        if (match(ch, /^[A-Za-z0-9_.~-]$/))
            push(out, ch);
        else
            push(out, sprintf("%%%02X", ord(value, i)));
    }
    return join("", out);
}

function module_capture(args) {
    if (getenv("TACHYON_DIAGNOSTICS_UC") == null && type(args) == "array" && length(args) > 0) {
        let action = as_string(args[0] || "");
        let info = priority_clash_info();
        if (action == "get_proxy_latency") {
            let tag_name = as_string(args[1] || "");
            let timeout_ms = as_string(args[2] || "2000");
            let health_url = as_string(args[3] || "https://www.gstatic.com/generate_204");
            let max_time = int((int(timeout_ms, 10) + 1999) / 1000);
            if (max_time < 2) max_time = 2;
            let endpoint = index(tag_name, "-urltest") >= 0
                ? (info.base_url + "/group/" + urlencode_segment(tag_name) + "/delay")
                : (info.base_url + "/proxies/" + urlencode_segment(tag_name) + "/delay");
            let curl_args = [ "curl", "-G", "-s", "-m", as_string(max_time), endpoint ];
            if (info.secret != "") {
                push(curl_args, "-H");
                push(curl_args, "Authorization: Bearer " + info.secret);
            }
            push(curl_args, "--data-urlencode");
            push(curl_args, "url=" + health_url);
            push(curl_args, "--data-urlencode");
            push(curl_args, "timeout=" + timeout_ms);
            return common.command_capture(command_from_args(curl_args));
        }
        if (action == "set_group_proxy") {
            let group_tag = as_string(args[1] || "");
            let proxy_tag = as_string(args[2] || "");
            let curl_args = [
                "curl", "-X", "PUT", "-s", "-m", "5", "-w", "\n%{http_code}",
                info.base_url + "/proxies/" + urlencode_segment(group_tag),
                "-H", "Content-Type: application/json"
            ];
            if (info.secret != "") {
                push(curl_args, "-H");
                push(curl_args, "Authorization: Bearer " + info.secret);
            }
            push(curl_args, "--data-raw");
            push(curl_args, sprintf("%J", { name: proxy_tag }));
            let res = common.command_capture(command_from_args(curl_args));
            if (res.status == 0 && match(res.output, /(^|\n)(200|204)\s*$/) != null) {
                let state_path = getenv("TACHYON_PERSISTENT_SELECTOR_STATE_FILE") || "/etc/tachyon/selector_state.json";
                let sel_state = read_json_file(state_path);
                if (type(sel_state) != "object") sel_state = {};
                sel_state[group_tag] = proxy_tag;
                common.write_json_file(state_path, sel_state, 2);
                return { status: 0, output: res.output };
            }
            return { status: 1, output: res.output };
        }
    }

    let command = command_from_args([ "ucode", "-L", LIB_DIR, DIAGNOSTICS_UC, "clash-api" ]);
    for (let arg in args)
        command += " " + shell_quote(arg);

    return common.command_capture(command);
}

function parse_delay_output(output) {
    let value = null;
    try {
        value = json(output);
    }
    catch (e) {
        return null;
    }

    if (type(value) != "object")
        return null;

    let delay = value.delay;
    if (delay == null || as_string(delay) == "") {
        let min_d = null;
        for (let k, v in value) {
            if (k == "message" || k == "error")
                continue;
            if (type(v) == "int" && v > 0) {
                if (min_d == null || v < min_d)
                    min_d = v;
            }
        }
        return min_d;
    }

    delay = int(delay, 10);
    return delay >= 0 ? delay : null;
}

function clash_probe(tag_name, group) {
    // Health timing can change without regenerating outbounds or restarting the core.
    // Keep the cache fallback for fixtures and groups without a current UCI owner.
    let uci = require("core.uci");
    let config = getenv("TACHYON_CONFIG_NAME") || "tachyon";
    let cursor = uci.cursor();
    if (cursor) { cursor.unload(config); cursor.load(config); }
    let live = uci.get_all(config, group.id);
    let check_timeout = type(live) == "object" && live[".type"] == "priority_group"
        ? common.option(live, "check_timeout", group.check_timeout) : group.check_timeout;
    let timeout = as_string(duration_to_milliseconds(check_timeout, 2000));
    let result = module_capture([ "get_proxy_latency", tag_name, timeout, group.health_url ]);
    if (result.status != 0)
        return { alive: false, delay: 0 };

    let delay = parse_delay_output(result.output);
    if (delay == null)
        return { alive: false, delay: 0 };

    return { alive: true, delay };
}

function fixture_probe(latencies, tag_name) {
    let value = object_or_empty(latencies)[tag_name];
    if (value == null || as_string(value) == "" || int(value, 10) < 0)
        return { alive: false, delay: 0 };
    return { alive: true, delay: int(value, 10) };
}

// The delays the core already measured. The clash API keeps a history per
// outbound, so one GET gives the delay of every node in the group without
// probing each one - which is what made "pick the fastest" expensive before.
//
// Returns null when the answer is not available, and the caller then falls
// back to probing the nodes one by one.
let cached_delays_mtime = -1;
let cached_delays = null;
// A fixture can hand the snapshot in directly, so the ordering logic is
// testable without a running core.
let fixture_delays_path = "";

// A fixture can hand the snapshot in directly, so the ordering logic is
// testable without a running core.
function fixture_delays_override() {
    if (fixture_delays_path == "")
        return null;
    let data = read_json_file(fixture_delays_path);
    return type(data) == "object" ? data : null;
}

function clash_delays_snapshot() {
    let override = fixture_delays_override();
    if (override != null)
        return override;

    let cfg_path = "/etc/tachyon-core/config.json";
    let st = fs.stat(cfg_path);
    let mtime = st ? int(st.mtime || 0) : 0;
    if (cached_delays_mtime == mtime && cached_delays != null)
        return cached_delays;

    let info = priority_clash_info();
    let curl_args = [ "curl", "-s", "-m", "5", info.base_url + "/proxies" ];
    if (info.secret != "") {
        push(curl_args, "-H");
        push(curl_args, "Authorization: Bearer " + info.secret);
    }
    let res = common.command_capture(command_from_args(curl_args));
    if (res.status != 0) {
        cached_delays_mtime = mtime;
        cached_delays = null;
        return null;
    }

    let body = null;
    try {
        body = json(res.output);
    }
    catch (e) {
        body = null;
    }
    let proxies = type(body) == "object" ? object_or_empty(body.proxies) : {};
    let delays = {};
    for (let name in proxies) {
        let history = object_or_empty(proxies[name]).history;
        if (type(history) != "array" || length(history) == 0)
            continue;
        let last = object_or_empty(history[length(history) - 1]);
        let delay = int(last.delay, 10);
        if (delay != null && delay >= 0)
            delays[as_string(name)] = delay;
    }

    cached_delays_mtime = mtime;
    cached_delays = delays;
    return delays;
}

// The measured delay of one node, or null when the core has no history for
// it. A node the core never measured is not a candidate: "the fastest" has to
// be the fastest of the ones that answered.
function measured_delay(tag_name) {
    let delays = clash_delays_snapshot();
    if (delays == null)
        return null;
    let value = delays[as_string(tag_name)];
    if (value == null)
        return null;
    return int(value, 10);
}

function choose_from_level(group, level_index, probe, skip_tag) {
    let level = object_or_empty(array_or_empty(group.levels)[level_index]);
    let best = null;
    let candidates = array_or_empty(level.outbounds);

    // The order the nodes are tried in. With pick_fastest on, the delays the
    // core already measured decide it - one GET on the clash API gives the
    // delay of every node in the group, instead of one probe per node.
    //
    // A measured delay says nothing about liveness - the node may have died
    // since the last measurement - so the order only decides who is tried
    // first, and the first node that actually answers wins.
    let measured = group.pick_fastest ? clash_delays_snapshot() : null;
    if (measured != null) {
        let ordered = [];
        let unordered = [];
        for (let tag_name in candidates) {
            if (as_string(skip_tag) != "" && tag_name == skip_tag)
                continue;
            let delay = measured[as_string(tag_name)];
            // A negative delay is a node the core could not reach. It still
            // has a place in the order - last - because it may answer now.
            if (delay == null || delay < 0) {
                push(unordered, tag_name);
                continue;
            }
            push(ordered, { tag: tag_name, delay: delay });
        }
        sort(ordered, function(a, b) { return a.delay - b.delay; });
        let result = [];
        for (let entry in ordered)
            push(result, entry.tag);
        for (let tag_name in unordered)
            push(result, tag_name);
        candidates = result;
    }

    for (let tag_name in candidates) {
        // The node that just failed must not be picked again - that is the
        // whole point of the replacement search.
        if (as_string(skip_tag) != "" && tag_name == skip_tag)
            continue;
        let result = probe(tag_name, group);
        if (!result.alive)
            continue;

        if (!group.pick_fastest)
            return {
                tag: tag_name,
                levelIndex: level_index,
                delay: result.delay
            };

        if (best == null || result.delay < best.delay)
            best = {
                tag: tag_name,
                levelIndex: level_index,
                delay: result.delay
            };
    }

    return best;
}

function choose_from_level_range(group, start_index, end_index, probe, skip_tag) {
    let levels = array_or_empty(group.levels);
    if (length(levels) == 0)
        return null;

    start_index = int(start_index || 0);
    end_index = int(end_index || 0);
    if (start_index < 0)
        start_index = 0;
    if (end_index >= length(levels))
        end_index = length(levels) - 1;
    if (start_index > end_index)
        return null;

    for (let i = start_index; i <= end_index; i++) {
        let selected = choose_from_level(group, i, probe, skip_tag);
        if (selected != null)
            return selected;
    }
    return null;
}

// A same-level switch costs every live connection, so it has to buy something.
// Single-shot RTT noise on a home line is tens of milliseconds; without a
// tolerance the group ping-pongs on noise and the user pays a reconnect every
// fastest_check_interval for a "gain" that was never real. Same default the
// sing-box urltest and the steer group pick use.
const FASTEST_SWITCH_TOLERANCE_MS = 50;

function choose_fastest_same_level(group, level_index, active_tag, probe) {
    let level = object_or_empty(array_or_empty(group.levels)[level_index]);
    let active = null;
    let best = null;

    for (let tag_name in array_or_empty(level.outbounds)) {
        let result = probe(tag_name, group);
        if (tag_name == active_tag)
            active = result;
        if (!result.alive)
            continue;
        if (best == null || result.delay < best.delay) {
            best = {
                tag: tag_name,
                levelIndex: level_index,
                delay: result.delay
            };
        }
    }

    if (best == null || best.tag == active_tag)
        return null;
    if (active == null || !active.alive || best.delay + FASTEST_SWITCH_TOLERANCE_MS <= active.delay)
        return best;
    return null;
}

function set_group_proxy(group, tag_name) {
    let result = module_capture([ "set_group_proxy", group.tag, tag_name, "" ]);
    return result.status == 0;
}

function switch_group(state, group, selected) {
    if (selected == null || selected.tag == "")
        return false;

    if (state.active == selected.tag) {
        state.levelIndex = selected.levelIndex;
        state.activeDelay = selected.delay;
        return true;
    }

    if (!set_group_proxy(group, selected.tag)) {
        log_message("failed to switch " + group.tag + " to " + selected.tag, "warn");
        return false;
    }

    state.active = selected.tag;
    state.levelIndex = selected.levelIndex;
    state.activeDelay = selected.delay;
    return true;
}

function init_group_state(group) {
    return {
        active: "",
        levelIndex: -1,
        activeDelay: 0,
        guard: reachability_guard.create({
            fail_threshold: 3,
            recover_threshold: 8,
            dwell_seconds: 120
        }),
        nextActiveCheck: now_seconds(),
        nextRecoveryCheck: now_seconds() + duration_to_seconds(group.recovery_check_interval, 15),
        nextFastestCheck: now_seconds() + duration_to_seconds(group.fastest_check_interval, 180)
    };
}

function tick_group(state, group) {
    let now = now_seconds();

    if (state.active == "" && now >= state.nextActiveCheck) {
        let selected = choose_from_level_range(group, 0, length(group.levels) - 1, clash_probe);
        if (switch_group(state, group, selected) && state.levelIndex > 0 && state.guard) {
            state.guard.escalated = true;
            state.guard.escalated_at = now;
            state.guard.ok_streak = 0;
        }
        state.nextActiveCheck = now + duration_to_seconds(group.active_check_interval, 5);
        return;
    }

    if (state.active != "" && now >= state.nextActiveCheck) {
        let active = clash_probe(state.active, group);
        if (active.alive) {
            state.activeDelay = active.delay;
            if (state.levelIndex == 0 && state.guard)
                reachability_guard.observe(state.guard, { direct_domestic: true, direct_foreign: true, tunnel_foreign: true, now: now });
        }
        else {
            if (state.guard)
                reachability_guard.observe(state.guard, { direct_domestic: true, direct_foreign: false, tunnel_foreign: false, now: now });
            let selected = choose_from_level_range(
                group,
                state.levelIndex,
                length(group.levels) - 1,
                clash_probe,
                state.active
            );
            if (switch_group(state, group, selected)) {
                if (state.levelIndex > 0 && state.guard && !state.guard.escalated) {
                    state.guard.escalated = true;
                    state.guard.escalated_at = now;
                    state.guard.ok_streak = 0;
                    push(state.guard.transitions, now);
                }
                state.nextRecoveryCheck = now + duration_to_seconds(group.recovery_check_interval, 15);
                state.nextFastestCheck = now + duration_to_seconds(group.fastest_check_interval, 180);
            }
            else {
                state.active = "";
                state.levelIndex = -1;
            }
        }
        state.nextActiveCheck = now + duration_to_seconds(group.active_check_interval, 5);
    }

    if (state.active != "" && state.levelIndex > 0 && now >= state.nextRecoveryCheck) {
        let selected = choose_from_level_range(group, 0, state.levelIndex - 1, clash_probe);
        let ready_to_return = selected != null;
        if (state.guard) {
            let snap = reachability_guard.observe(state.guard, {
                direct_domestic: true,
                direct_foreign: selected != null,
                tunnel_foreign: selected != null,
                now: now
            });
            ready_to_return = (selected != null && !snap.escalated);
        }
        if (ready_to_return && switch_group(state, group, selected))
            state.nextFastestCheck = now + duration_to_seconds(group.fastest_check_interval, 180);
        state.nextRecoveryCheck = now + duration_to_seconds(group.recovery_check_interval, 15);
    }

    if (state.active != "" && group.switch_to_faster_same_priority && now >= state.nextFastestCheck) {
        let selected = choose_fastest_same_level(group, state.levelIndex, state.active, clash_probe);
        if (selected != null)
            switch_group(state, group, selected);
        state.nextFastestCheck = now + duration_to_seconds(group.fastest_check_interval, 180);
    }
}

function worker() {
    let groups = priority_groups_from_cache();
    if (length(groups) == 0)
        return 0;

    let states = {};
    let min_interval = 5;
    for (let group in groups) {
        states[group.tag] = init_group_state(group);
        let interval = duration_to_seconds(group.active_check_interval, 5);
        if (interval < min_interval)
            min_interval = interval;
    }
    if (min_interval < 1) min_interval = 1;

    while (true) {
        for (let group in groups)
            tick_group(states[group.tag], group);
        command_success_from_args([ "sleep", as_string(min_interval) ]);
    }
}

function process_running(pid) {
    pid = trim(as_string(pid));
    return pid != "" && match(pid, /^[0-9]+$/) != null && command_success_from_args([ "kill", "-0", pid ]);
}

function stop_runtime() {
    let pid = file_first_line(PRIORITY_PID_FILE);
    if (process_running(pid)) {
        command_success_from_args([ "kill", pid ]);
        let wait_limit = 30;
        while (wait_limit > 0 && process_running(pid)) {
            sleep(100);
            wait_limit--;
        }
        if (process_running(pid))
            command_success_from_args([ "kill", "-9", pid ]);
    }
    remove_file(PRIORITY_PID_FILE);
    return 0;
}

function start_runtime() {
    let groups = priority_groups_from_cache();
    stop_runtime();
    if (length(groups) == 0)
        return 0;

    if (!ensure_dir(RUNTIME_STATE_DIR))
        return 1;

    let command = common.background_command_with_pid(
        command_from_args([ "ucode", "-L", LIB_DIR, PRIORITY_UC, "worker" ]),
        ">/dev/null", ">" + shell_quote(PRIORITY_PID_FILE));
    return command_status(command);
}

function select_fixture(group_path, latency_path, start_index, end_index, skip_tag) {
    let group = normalize_group(read_json_file(group_path), "fixture");
    let latencies = object_or_empty(read_json_file(latency_path));
    // The same file feeds the measured-delay snapshot, so the ordering logic
    // runs exactly as it does on a live core.
    fixture_delays_path = as_string(latency_path);
    let selected = choose_from_level_range(group, start_index, end_index, function(tag_name, _group) {
        return fixture_probe(latencies, tag_name);
    }, skip_tag);
    write_json(selected == null ? {} : selected);
}

function select_faster_fixture(group_path, latency_path, level_index, active_tag) {
    let group = normalize_group(read_json_file(group_path), "fixture");
    let latencies = object_or_empty(read_json_file(latency_path));
    let selected = choose_fastest_same_level(group, int(level_index || 0), as_string(active_tag), function(tag_name, _group) {
        return fixture_probe(latencies, tag_name);
    });
    write_json(selected == null ? {} : selected);
}

let mode = ARGV[0] || "";

if (mode == "start-runtime")
    exit(start_runtime());
else if (mode == "stop-runtime")
    exit(stop_runtime());
else if (mode == "worker")
    exit(worker());
else if (mode == "select-fixture")
    select_fixture(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]);
else if (mode == "select-faster-fixture")
    select_faster_fixture(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else {
    warn("Usage: singbox/priority.uc <start-runtime|stop-runtime|worker|select-fixture|select-faster-fixture>\n");
    exit(1);
}
