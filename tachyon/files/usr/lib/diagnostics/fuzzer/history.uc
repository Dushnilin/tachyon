#!/usr/bin/env ucode
//
// Fuzzer history, state and job-directory helpers.
//
// Extracted from diagnostics/fuzzer.uc (branch 6 god-module split). Pure
// persistence: history entries, the worker state file and per-job directories.
//

let fs = require("fs");
let common = require("core.common");

let as_string = common.as_string;
let read_json_file = common.read_json_file;
let write_json_file = common.write_json_file;
let command_success_from_args = common.command_success_from_args;
let shell_quote = common.shell_quote;

const STATE_DIR = getenv("TACHYON_FUZZER_STATE_DIR") || "/var/run/tachyon";
const STATE_FILE = STATE_DIR + "/fuzzer-state.json";
const PID_FILE = STATE_DIR + "/fuzzer-worker.pid";
const JOBS_DIR = STATE_DIR + "/fuzzer";
const HISTORY_FILE = "/etc/tachyon/fuzzer_history.json";

function get_job_dir(job_id) {
    if (!job_id || job_id == "") return null;
    return JOBS_DIR + "/" + job_id;
}

const JOB_DIR_MAX_AGE_SECONDS = 3600;

function job_dir_in_use(dir) {
    for (let name in [ "worker.pid", "engine.pid", "probe.pid" ]) {
        let pid = trim(as_string(fs.readfile(dir + "/" + name) || ""));
        if (match(pid, /^[0-9]+$/) != null && fs.stat("/proc/" + pid) != null)
            return true;
    }
    return false;
}

// cleanup_temp_daemons() runs repeatedly inside one job, so the directory
// itself cannot be removed there. The next job start is the natural moment to
// reclaim the ones left by finished runs; /var/run is RAM.
function gc_job_dirs(keep_job_id) {
    let now = time();
    for (let entry in (fs.lsdir(JOBS_DIR) || [])) {
        if (entry == "." || entry == ".." || entry == as_string(keep_job_id))
            continue;
        let dir = JOBS_DIR + "/" + entry;
        let st = fs.stat(dir);
        if (st == null || st.type != "directory" || now - int(st.mtime || 0) < JOB_DIR_MAX_AGE_SECONDS)
            continue;
        if (job_dir_in_use(dir))
            continue;
        command_success_from_args([ "rm", "-rf", dir ]);
    }
}

function ensure_job_dir(job_id) {
    if (!job_id || job_id == "") return null;
    let d = JOBS_DIR + "/" + job_id;
    system(sprintf("mkdir -p %s 2>/dev/null", shell_quote(d)));
    gc_job_dirs(job_id);
    return d;
}

function load_history() {
    let data = read_json_file(HISTORY_FILE);
    if (data && type(data) == "object" && data.entries && type(data.entries) == "array") {
        return data;
    }
    return { entries: [] };
}

function save_history(history) {
    if (type(history) != "object" || type(history.entries) != "array")
        return false;
    return write_json_file(HISTORY_FILE, history) != null;
}

function append_history(entry) {
    if (type(entry) != "object")
        return false;
    let history = load_history();
    push(history.entries, entry);
    // Cap the history so the file cannot grow without bound on a long-lived
    // router; keep the newest entries.
    let max_entries = 500;
    if (length(history.entries) > max_entries)
        history.entries = slice(history.entries, length(history.entries) - max_entries);
    return save_history(history);
}

function get_history(limit) {
    let history = load_history();
    let entries = history.entries;
    if (int(limit || 0) > 0 && length(entries) > int(limit))
        entries = slice(entries, length(entries) - int(limit));
    // Newest first, as the UI expects.
    let out = [];
    for (let i = length(entries) - 1; i >= 0; i--)
        push(out, entries[i]);
    return out;
}

function clear_history() {
    return save_history({ entries: [] });
}

function ensure_state_dir() {
    return command_success_from_args([ "mkdir", "-p", STATE_DIR ]);
}

function save_fuzzer_state(state) {
    ensure_state_dir();
    if (state && type(state) == "object") {
        let force = state._force === true;
        delete state._force;
        if (!force) {
            let cur = read_json_file(STATE_FILE);
            if (cur && type(cur) == "object") {
                if (cur.job_id && state.job_id && cur.job_id != state.job_id)
                    return false;
                if (cur.aborted === true && state.aborted !== true)
                    return false;
            }
        }
    }
    return write_json_file(STATE_FILE, state) != null;
}

function is_job_aborted(job_id) {
    let cur = read_json_file(STATE_FILE);
    if (!cur || type(cur) != "object")
        return false;
    if (cur.aborted === true)
        return true;
    if (job_id && cur.job_id && cur.job_id != job_id)
        return true;
    return false;
}

function get_fuzzer_state() {
    let state = read_json_file(STATE_FILE);
    if (!state || type(state) != "object") {
        return {
            running: false,
            job_id: null,
            engine: "zapret2",
            target: "youtube_suite",
            progress_pct: 0,
            current_index: 0,
            total_strategies: 0,
            current_strategy: null,
            results: [],
            best_strategy: null,
            error: null,
            started_at: 0,
            finished_at: 0
        };
    }
    if (state.running) {
        let is_alive = false;
        let pid_str = fs.readfile(PID_FILE);
        if (pid_str) {
            let pid = trim(as_string(pid_str));
            if (pid != "" && match(pid, /^[0-9]+$/) != null)
                is_alive = (system(sprintf("kill -0 %s >/dev/null 2>&1", pid)) == 0);
        }
        if (!is_alive && state.job_id) {
            let j_dir = get_job_dir(state.job_id);
            if (j_dir) {
                let j_pid_str = fs.readfile(j_dir + "/worker.pid");
                if (j_pid_str) {
                    let j_pid = trim(as_string(j_pid_str));
                    if (j_pid != "" && match(j_pid, /^[0-9]+$/) != null)
                        is_alive = (system(sprintf("kill -0 %s >/dev/null 2>&1", j_pid)) == 0);
                }
            }
        }
        if (!is_alive) {
            state.running = false;
            if (!state.error && state.progress_pct < 100)
                state.error = "Worker process exited unexpectedly";
            if (state.finished_at == 0)
                state.finished_at = clock()[0];
            save_fuzzer_state(state);
        }
    }
    return state;
}

function safe_json_parse(str) {
    str = as_string(str);
    if (trim(str) == "")
        return null;
    try {
        return json(str);
    }
    catch (e) {
        return null;
    }
}

function module_exports() {
    return {
        STATE_DIR,
        STATE_FILE,
        PID_FILE,
        JOBS_DIR,
        HISTORY_FILE,
        get_job_dir,
        ensure_job_dir,
        load_history,
        save_history,
        append_history,
        get_history,
        clear_history,
        ensure_state_dir,
        save_fuzzer_state,
        is_job_aborted,
        get_fuzzer_state,
        safe_json_parse
    };
}

return module_exports();
