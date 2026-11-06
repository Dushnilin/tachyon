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

function normalize_urls(primary_url, extra_urls) {
    let urls = [];
    let seen = {};
    let p = trim(as_string(primary_url || "https://www.gstatic.com/generate_204"));
    if (p == "")
        p = "https://www.gstatic.com/generate_204";
    seen[p] = true;
    push(urls, p);
    for (let u in array_or_empty(extra_urls)) {
        for (let tok in split(as_string(u || ""), /[ \t\r\n,]+/)) {
            tok = trim(as_string(tok));
            if (tok != "" && !seen[tok]) {
                seen[tok] = true;
                push(urls, tok);
            }
        }
    }
    return urls;
}

function normalize_strategy(strategy) {
    let s = lc(trim(as_string(strategy || "worst_case")));
    if (s == "worst_case" || s == "best_case" || s == "best_case_target" || s == "average")
        return s;
    return "worst_case";
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

    let primary_url = as_string(group.health_url || group.url || "https://www.gstatic.com/generate_204");
    let extra_urls = group.health_urls != null ? group.health_urls : group.testing_urls;
    let tol = int(group.tolerance || 50, 10);
    if (tol <= 0)
        tol = 50;
    return {
        id: as_string(group.id || ""),
        tag: as_string(group.tag || tag_name),
        kind: as_string(group.kind || "priority"),
        section: as_string(group.section || ""),
        displayName: as_string(group.displayName || group.name || tag_name),
        health_url: primary_url,
        health_urls: normalize_urls(primary_url, extra_urls),
        multi_url_strategy: normalize_strategy(group.multi_url_strategy),
        active_check_interval: as_string(group.active_check_interval || "5s"),
        check_timeout: as_string(group.check_timeout || "2s"),
        recovery_check_interval: as_string(group.recovery_check_interval || "15s"),
        pick_fastest: bool_value(group.pick_fastest, false),
        switch_to_faster_same_priority: bool_value(group.switch_to_faster_same_priority, false),
        fastest_check_interval: as_string(group.fastest_check_interval || "3m"),
        tolerance: tol,
        min_hold_time: as_string(group.min_hold_time || "15s"),
        levels
    };
}

function normalize_urltest_active_group(group, tag_name, section_name) {
    group = object_or_empty(group);
    let active_interval = trim(as_string(group.active_check_interval || ""));
    let extra_urls = array_or_empty(group.testing_urls);
    if (active_interval == "" && length(extra_urls) == 0)
        return null;
    if (active_interval == "")
        active_interval = as_string(group.interval || "3m");
    let outbounds = [];
    for (let o in array_or_empty(group.outbounds)) {
        o = as_string(o);
        if (o != "")
            push(outbounds, o);
    }
    if (length(outbounds) == 0)
        return null;
    let primary_url = as_string(group.url || "https://www.gstatic.com/generate_204");
    return {
        id: as_string(tag_name),
        tag: as_string(tag_name),
        kind: "urltest",
        section: as_string(section_name || ""),
        displayName: as_string(group.displayName || tag_name),
        health_url: primary_url,
        health_urls: normalize_urls(primary_url, extra_urls),
        multi_url_strategy: normalize_strategy(group.multi_url_strategy),
        active_check_interval: active_interval,
        check_timeout: "3s",
        recovery_check_interval: as_string(group.interval || "3m"),
        pick_fastest: true,
        switch_to_faster_same_priority: false,
        fastest_check_interval: as_string(group.interval || "3m"),
        levels: [
            {
                id: as_string(tag_name) + "_pool",
                displayName: as_string(group.displayName || tag_name),
                order: 1,
                outbounds
            }
        ]
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
        let section_name = as_string(cache.section || "");
        for (let tag_name, group in object_or_empty(cache.priorityGroups)) {
            let normalized = normalize_group(group, tag_name);
            if (normalized.tag != "" && length(normalized.levels) > 0)
                push(result, normalized);
        }
        for (let tag_name, ut_group in object_or_empty(cache.urltestGroups)) {
            let normalized_ut = normalize_urltest_active_group(ut_group, tag_name, section_name);
            if (normalized_ut != null)
                push(result, normalized_ut);
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

let recent_probe_cache = {};
const PROBE_DEDUP_TTL_S = 3;

function module_capture(args) {
    let is_latency_probe = type(args) == "array" && length(args) > 0 && as_string(args[0] || "") == "get_proxy_latency";
    let probe_cache_key = "";
    let now_s = 0;
    if (is_latency_probe) {
        now_s = now_seconds();
        probe_cache_key = as_string(args[1] || "") + "|" + as_string(args[2] || "2000") + "|" + as_string(args[3] || "https://www.gstatic.com/generate_204");
        let cached = recent_probe_cache[probe_cache_key];
        if (cached != null && (now_s - cached.at) <= PROBE_DEDUP_TTL_S)
            return cached.res;
    }

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
            let res = common.command_capture(command_from_args(curl_args));
            recent_probe_cache[probe_cache_key] = { at: now_s, res };
            return res;
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
                return { status: 0, output: res.output };
            }
            return { status: 1, output: res.output };
        }
    }

    let command = command_from_args([ "ucode", "-L", LIB_DIR, DIAGNOSTICS_UC, "clash-api" ]);
    for (let arg in args)
        command += " " + shell_quote(arg);

    let res = common.command_capture(command);
    if (is_latency_probe && probe_cache_key != "")
        recent_probe_cache[probe_cache_key] = { at: now_s, res };
    return res;
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

function evaluate_multi_url_delays(delays_by_url, urls, strategy) {
    let total = length(urls);
    if (total == 0)
        return { alive: false, delay: 0, passed: 0, total: 0, full_pass: false };
    let passed = 0;
    let max_delay = 0;
    let min_delay = null;
    let sum_delay = 0;
    let primary_delay = null;

    for (let i = 0; i < total; i++) {
        let u = urls[i];
        let d = delays_by_url[u];
        if (d != null && d >= 0) {
            passed++;
            if (i == 0)
                primary_delay = d;
            if (d > max_delay)
                max_delay = d;
            if (min_delay == null || d < min_delay)
                min_delay = d;
            sum_delay += d;
        }
    }

    if (passed == 0)
        return { alive: false, delay: 0, passed: 0, total, full_pass: false };

    let full_pass = (passed == total);
    let combined = max_delay;
    strategy = normalize_strategy(strategy);
    if (strategy == "best_case")
        combined = min_delay != null ? min_delay : max_delay;
    else if (strategy == "best_case_target")
        combined = primary_delay != null ? primary_delay : (min_delay != null ? min_delay : max_delay);
    else if (strategy == "average")
        combined = int((sum_delay + int(passed / 2)) / passed);

    return {
        alive: true,
        delay: combined,
        passed,
        total,
        full_pass,
        delays_by_url
    };
}

function clash_probe(tag_name, group) {
    // Health timing can change without regenerating outbounds or restarting the core.
    // Keep the cache fallback for fixtures and groups without a current UCI owner.
    let uci = require("core.uci");
    let config = getenv("TACHYON_CONFIG_NAME") || "tachyon";
    let cursor = uci.cursor();
    if (cursor) { cursor.unload(config); cursor.load(config); }
    let live = uci.get_all(config, group.id);
    let check_timeout = type(live) == "object" && (live[".type"] == "priority_group" || live[".type"] == "balancer")
        ? common.option(live, "check_timeout", group.check_timeout) : group.check_timeout;
    let timeout = as_string(duration_to_milliseconds(check_timeout, 2000));
    let urls = type(group.health_urls) == "array" ? group.health_urls : [];
    if (length(urls) <= 1) {
        let url = length(urls) == 1 ? as_string(urls[0]) : as_string(group.health_url || "https://www.gstatic.com/generate_204");
        let result = module_capture([ "get_proxy_latency", tag_name, timeout, url ]);
        if (result.status != 0)
            return { alive: false, delay: 0, passed: 0, total: 1, full_pass: false };
        let delay = parse_delay_output(result.output);
        if (delay == null)
            return { alive: false, delay: 0, passed: 0, total: 1, full_pass: false };
        if (type(group._url_delays) != "object")
            group._url_delays = {};
        group._url_delays[as_string(tag_name)] = { [url]: delay };
        return { alive: true, delay, passed: 1, total: 1, full_pass: true, delays_by_url: { [url]: delay } };
    }

    let delays_by_url = {};
    for (let u in urls) {
        let result = module_capture([ "get_proxy_latency", tag_name, timeout, u ]);
        if (result.status == 0) {
            let d = parse_delay_output(result.output);
            if (d != null && d >= 0)
                delays_by_url[u] = d;
        }
    }
    if (type(group._url_delays) != "object")
        group._url_delays = {};
    group._url_delays[as_string(tag_name)] = delays_by_url;
    return evaluate_multi_url_delays(delays_by_url, urls, group.multi_url_strategy);
}

function fixture_probe(latencies, tag_name, group) {
    let raw = object_or_empty(latencies)[tag_name];
    let urls = group != null && length(array_or_empty(group.health_urls)) > 0
        ? array_or_empty(group.health_urls)
        : [ as_string((group && group.health_url) || "https://www.gstatic.com/generate_204") ];
    let strategy = group != null ? group.multi_url_strategy : "worst_case";

    if (type(raw) == "object") {
        let delays_by_url = {};
        for (let u in urls) {
            let v = raw[u];
            if (v != null && as_string(v) != "" && int(v, 10) >= 0)
                delays_by_url[u] = int(v, 10);
        }
        if (group != null && type(group) == "object") {
            if (type(group._url_delays) != "object")
                group._url_delays = {};
            group._url_delays[as_string(tag_name)] = delays_by_url;
        }
        return evaluate_multi_url_delays(delays_by_url, urls, strategy);
    }

    if (raw == null || as_string(raw) == "" || int(raw, 10) < 0)
        return { alive: false, delay: 0, passed: 0, total: length(urls), full_pass: false };
    let d = int(raw, 10);
    if (group != null && type(group) == "object") {
        if (type(group._url_delays) != "object")
            group._url_delays = {};
        let primary_url = length(urls) > 0 ? as_string(urls[0]) : "https://www.gstatic.com/generate_204";
        group._url_delays[as_string(tag_name)] = { [primary_url]: d };
    }
    return { alive: true, delay: d, passed: length(urls), total: length(urls), full_pass: true };
}

// The delays the core already measured. The clash API keeps a history per
// outbound, so one GET gives the delay of every node in the group without
// probing each one - which is what made "pick the fastest" expensive before.
//
// Returns null when the answer is not available, and the caller then falls
// back to probing the nodes one by one.
let cached_delays_mtime = -1;
let cached_delays_at = -1;
let cached_delays = null;
const CLASH_DELAYS_CACHE_TTL_S = 10;
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
    let now = now_seconds();
    if (cached_delays_mtime == mtime && cached_delays != null &&
        cached_delays_at >= 0 && (now - cached_delays_at) < CLASH_DELAYS_CACHE_TTL_S)
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
        cached_delays_at = now;
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
    cached_delays_at = now;
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
    let best_fallback = null;
    let candidates = array_or_empty(level.outbounds);
    let is_multi_url = length(array_or_empty(group.health_urls)) > 1;

    // The order the nodes are tried in. With pick_fastest on, the delays the
    // core already measured decide it - one GET on the clash API gives the
    // delay of every node in the group, instead of one probe per node.
    //
    // A measured delay says nothing about liveness - the node may have died
    // since the last measurement - so the order only decides who is tried
    // first, and the first node that actually answers wins.
    let measured = (!is_multi_url && group.pick_fastest) ? clash_delays_snapshot() : null;
    let ordered_tags = {};
    if (measured != null) {
        let ordered = [];
        let unordered = [];
        for (let tag_name in candidates) {
            if (as_string(skip_tag) != "" && tag_name == skip_tag)
                continue;
            let delay = measured[as_string(tag_name)];
            if ( type(delay) == "object" )
                delay = null;
            // A negative delay is a node the core could not reach. It still
            // has a place in the order - last - because it may answer now.
            if (delay == null || delay < 0) {
                push(unordered, tag_name);
                continue;
            }
            ordered_tags[as_string(tag_name)] = true;
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

        let full_pass = result.full_pass !== false;
        let passed = result.passed != null ? int(result.passed) : 1;
        let total = result.total != null ? int(result.total) : 1;

        if (full_pass) {
            if (!group.pick_fastest || ordered_tags[as_string(tag_name)]) {
                let out = {
                    tag: tag_name,
                    levelIndex: level_index,
                    delay: result.delay
                };
                if (is_multi_url) {
                    out.fallback_active = false;
                    out.passed_urls = passed;
                    out.total_urls = total;
                }
                return out;
            }

            if (best == null || result.delay < best.delay) {
                best = {
                    tag: tag_name,
                    levelIndex: level_index,
                    delay: result.delay
                };
                if (is_multi_url) {
                    best.fallback_active = false;
                    best.passed_urls = passed;
                    best.total_urls = total;
                }
            }
        } else if (passed > 0) {
            if (best_fallback == null ||
                passed > best_fallback.passed_urls ||
                (passed == best_fallback.passed_urls && result.delay < best_fallback.delay)) {
                best_fallback = {
                    tag: tag_name,
                    levelIndex: level_index,
                    delay: result.delay,
                    fallback_active: true,
                    passed_urls: passed,
                    total_urls: total
                };
            }
        }
    }

    return best != null ? best : best_fallback;
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
// sing-box urltest uses.
const FASTEST_SWITCH_TOLERANCE_MS = 50;

function choose_fastest_same_level(group, level_index, active_tag, probe) {
    let level = object_or_empty(array_or_empty(group.levels)[level_index]);
    let active = null;
    let best = null;
    let tol = group && group.tolerance != null && int(group.tolerance, 10) > 0
        ? int(group.tolerance, 10)
        : FASTEST_SWITCH_TOLERANCE_MS;

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
    if (active == null || !active.alive || best.delay + tol <= active.delay)
        return best;
    return null;
}

function current_group_selected(group_tag) {
    let info = priority_clash_info();
    let curl_args = [ "curl", "-s", "-m", "4", info.base_url + "/proxies/" + urlencode_segment(group_tag) ];
    if (info.secret != "") {
        push(curl_args, "-H");
        push(curl_args, "Authorization: Bearer " + info.secret);
    }
    let res = common.command_capture(command_from_args(curl_args));
    if (res.status != 0)
        return "";
    let body = null;
    try { body = json(res.output); } catch (e) { body = null; }
    return type(body) == "object" ? as_string(body.now || "") : "";
}

function trigger_urltest_recheck(group) {
    let timeout = as_string(duration_to_milliseconds(group.check_timeout, 3000));
    let res = module_capture([ "get_group_latency", group.tag, timeout, group.health_url ]);
    cached_delays_mtime = -1;
    return res.status == 0;
}

function set_group_proxy(group, tag_name) {
    if (group.kind == "urltest") {
        let target_member = as_string(tag_name);
        if (target_member != "" && target_member != group.tag) {
            let info = priority_clash_info();
            let curl_args = [
                "curl", "-X", "PUT", "-s", "-m", "4",
                info.base_url + "/proxies/" + urlencode_segment(group.tag)
            ];
            if (info.secret != "") {
                push(curl_args, "-H");
                push(curl_args, "Authorization: Bearer " + info.secret);
            }
            push(curl_args, "--data-raw");
            push(curl_args, sprintf("%J", { name: target_member }));
            common.command_status(command_from_args(curl_args));
        } else {
            trigger_urltest_recheck(group);
        }
        return true;
    }
    let result = module_capture([ "set_group_proxy", group.tag, tag_name, "ephemeral" ]);
    return result.status == 0;
}

function write_group_status(group, state, selected) {
    let status_dir = RUNTIME_STATE_DIR + "/priority";
    if (!ensure_dir(status_dir))
        return;
    let url_delays = type(group._url_delays) == "object" ? group._url_delays : {};
    let payload = {
        tag: group.tag,
        kind: group.kind || "priority",
        active: state.active,
        levelIndex: state.levelIndex,
        delay: state.activeDelay,
        fallback_active: !!(selected && selected.fallback_active),
        passed_urls: selected && selected.passed_urls != null ? int(selected.passed_urls) : length(array_or_empty(group.health_urls)),
        total_urls: selected && selected.total_urls != null ? int(selected.total_urls) : length(array_or_empty(group.health_urls)),
        strategy: group.multi_url_strategy || "worst_case",
        active_check_interval: group.active_check_interval || "",
        urls: array_or_empty(group.health_urls),
        url_delays: url_delays,
        updated_at: now_seconds()
    };
    common.write_json_file(status_dir + "/" + urlencode_segment(group.tag) + ".json", payload);
}

function record_selector_transition(group, prev_active, prev_delay, selected, reason) {
    if (!ensure_dir(RUNTIME_STATE_DIR))
        return;
    let events_file = RUNTIME_STATE_DIR + "/selector_events.json";
    let events = array_or_empty(read_json_file(events_file));
    push(events, {
        ts: now_seconds(),
        group: as_string(group.tag || ""),
        from: as_string(prev_active || ""),
        to: as_string(selected.tag || ""),
        from_delay: int(prev_delay || 0),
        to_delay: int(selected.delay || 0),
        level: int(selected.levelIndex || 0),
        reason: as_string(reason || "switch")
    });
    if (length(events) > 50) {
        let trimmed = [];
        for (let i = length(events) - 50; i < length(events); i++)
            push(trimmed, events[i]);
        events = trimmed;
    }
    common.write_json_file(events_file, events);
}

function switch_group(state, group, selected, reason) {
    if (selected == null || selected.tag == "")
        return false;

    if (state.active == selected.tag) {
        state.levelIndex = selected.levelIndex;
        state.activeDelay = selected.delay;
        write_group_status(group, state, selected);
        return true;
    }

    if (!set_group_proxy(group, selected.tag)) {
        log_message("failed to switch " + group.tag + " to " + selected.tag, "warn");
        return false;
    }

    let prev_active = state.active;
    let prev_delay = state.activeDelay;
    state.active = selected.tag;
    state.levelIndex = selected.levelIndex;
    state.activeDelay = selected.delay;
    state.lastSwitchAt = now_seconds();
    write_group_status(group, state, selected);
    record_selector_transition(group, prev_active, prev_delay, selected, reason || (prev_active == "" ? "initial" : "switch"));
    return true;
}

function init_group_state(group) {
    return {
        active: "",
        levelIndex: -1,
        activeDelay: 0,
        lastSwitchAt: 0,
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

function warm_inactive_group_members(group, active_level_index, active_tag, probe, force_all, skip_active_level) {
    if (type(group) != "object" || (group.kind == "urltest" && length(array_or_empty(group.health_urls)) <= 1))
        return 0;

    let levels = array_or_empty(group.levels);
    let existing_delays = type(group._url_delays) == "object" ? group._url_delays : {};
    let snapshot = !force_all ? object_or_empty(clash_delays_snapshot()) : {};
    let seen = {};
    if (active_tag != null && as_string(active_tag) != "")
        seen[as_string(active_tag)] = true;

    let probed = 0;
    for (let i = 0; i < length(levels); i++) {
        if (skip_active_level && i == active_level_index)
            continue;
        let level = levels[i];
        if (type(level) != "object" || level.direct)
            continue;
        for (let raw_tag in array_or_empty(level.outbounds)) {
            let tag_name = as_string(raw_tag);
            if (tag_name == "" || tag_name == "direct-out" || seen[tag_name] == true)
                continue;
            seen[tag_name] = true;
            if (!force_all && (existing_delays[tag_name] != null || snapshot[tag_name] != null))
                continue;
            probe(tag_name, group);
            probed++;
        }
    }
    if (probed > 0)
        cached_delays_mtime = -1;
    return probed;
}

function tick_group(state, group) {
    let now = now_seconds();

    if (group.kind == "urltest" && state.active == "") {
        let current_now = current_group_selected(group.tag);
        if (current_now != "") {
            state.active = current_now;
            state.levelIndex = 0;
        }
    }

    if (state.active == "" && now >= state.nextActiveCheck) {
        if (group.kind == "urltest" && fixture_delays_path == "") {
            let snap = object_or_empty(clash_delays_snapshot());
            let has_measured = false;
            let total_candidates = 0;
            for (let lvl in array_or_empty(group.levels)) {
                for (let cand in array_or_empty(object_or_empty(lvl).outbounds)) {
                    total_candidates++;
                    let d = snap[as_string(cand)];
                    if (d != null && int(d, 10) > 0) {
                        has_measured = true;
                        break;
                    }
                }
                if (has_measured)
                    break;
            }
            if (!has_measured && total_candidates > 1)
                trigger_urltest_recheck(group);
        }
        let selected = choose_from_level_range(group, 0, length(group.levels) - 1, clash_probe);
        if (switch_group(state, group, selected, "initial") && state.levelIndex > 0 && state.guard) {
            state.guard.escalated = true;
            state.guard.escalated_at = now;
            state.guard.ok_streak = 0;
        }
        if (state.active != "" && warm_inactive_group_members(group, state.levelIndex, state.active, clash_probe, false, false) > 0)
            write_group_status(group, state, selected);
        state.nextActiveCheck = now + duration_to_seconds(group.active_check_interval, 5);
        return;
    }

    if (state.active != "" && now >= state.nextActiveCheck) {
        let active = clash_probe(state.active, group);
        if (active.alive) {
            state.activeDelay = active.delay;
            if (group.kind == "urltest" && length(array_or_empty(group.health_urls)) > 1)
                warm_inactive_group_members(group, state.levelIndex, state.active, clash_probe, false, false);
            write_group_status(group, state, {
                tag: state.active,
                levelIndex: state.levelIndex,
                delay: active.delay,
                fallback_active: active.full_pass === false,
                passed_urls: active.passed,
                total_urls: active.total
            });
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
            if (switch_group(state, group, selected, "failover")) {
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
        if (ready_to_return && switch_group(state, group, selected, "recovery"))
            state.nextFastestCheck = now + duration_to_seconds(group.fastest_check_interval, 180);
        state.nextRecoveryCheck = now + duration_to_seconds(group.recovery_check_interval, 15);
    }

    if (state.active != "" && now >= state.nextFastestCheck) {
        let same_level_probed = false;
        if (group.switch_to_faster_same_priority) {
            let min_hold = duration_to_seconds(group.min_hold_time, 15);
            if (state.lastSwitchAt <= 0 || (now - state.lastSwitchAt) >= min_hold) {
                same_level_probed = true;
                let selected = choose_fastest_same_level(group, state.levelIndex, state.active, clash_probe);
                if (selected != null)
                    switch_group(state, group, selected, "faster_same_tier");
            }
        }
        if (warm_inactive_group_members(group, state.levelIndex, state.active, clash_probe, true, same_level_probed) > 0) {
            write_group_status(group, state, {
                tag: state.active,
                levelIndex: state.levelIndex,
                delay: state.activeDelay
            });
        }
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
    let selected = choose_from_level_range(group, start_index, end_index, function(tag_name, grp) {
        return fixture_probe(latencies, tag_name, grp);
    }, skip_tag);
    write_json(selected == null ? {} : selected);
}

function select_faster_fixture(group_path, latency_path, level_index, active_tag) {
    let group = normalize_group(read_json_file(group_path), "fixture");
    let latencies = object_or_empty(read_json_file(latency_path));
    let selected = choose_fastest_same_level(group, int(level_index || 0), as_string(active_tag), function(tag_name, grp) {
        return fixture_probe(latencies, tag_name, grp);
    });
    write_json(selected == null ? {} : selected);
}

function warm_fixture(group_path, latency_path) {
    let group = normalize_group(read_json_file(group_path), "fixture");
    let latencies = object_or_empty(read_json_file(latency_path));
    let probe = function(tag_name, grp) {
        return fixture_probe(latencies, tag_name, grp);
    };
    let selected = choose_from_level_range(group, 0, length(group.levels) - 1, probe);
    let active_level = selected != null ? int(selected.levelIndex) : -1;
    let active_tag = selected != null ? as_string(selected.tag) : "";
    let probed = warm_inactive_group_members(group, active_level, active_tag, probe, false, false);
    write_json({
        selected: selected == null ? {} : selected,
        probed_inactive: probed,
        url_delays: type(group._url_delays) == "object" ? group._url_delays : {}
    });
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
else if (mode == "warm-fixture")
    warm_fixture(ARGV[1], ARGV[2]);
else {
    warn("Usage: singbox/priority.uc <start-runtime|stop-runtime|worker|select-fixture|select-faster-fixture|warm-fixture>\n");
    exit(1);
}
