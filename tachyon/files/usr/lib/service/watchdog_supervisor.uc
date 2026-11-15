#!/usr/bin/env ucode
//
// Lightweight watchdog supervisor daemon.
// Extracted from service/watchdog.uc so the long-lived supervisor process
// does not compile or retain the 3,600-line watchdog healer graph in RAM.
//

let fs = require("fs");
let common = require("core.common");

const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const PID_FILE = getenv("TACHYON_WATCHDOG_PID_FILE") || "/var/run/tachyon_watchdog.pid";
const WATCHDOG_UC = LIB_DIR + "/service/watchdog.uc";
const WORKER_UC = getenv("TACHYON_WATCHDOG_WORKER_UC") || WATCHDOG_UC;
const WORKER_ERR_FILE = getenv("TACHYON_WATCHDOG_ERR_FILE") || "/tmp/tachyon_watchdog_worker.err";
const WORKER_ERR_MAX_BYTES = int(getenv("TACHYON_WATCHDOG_ERR_MAX_BYTES") || "65536");
const WORKER_ERR_KEEP_BYTES = int(getenv("TACHYON_WATCHDOG_ERR_KEEP_BYTES") || "16384");
const WORKER_RESTART_DELAY_MS = int(getenv("TACHYON_WATCHDOG_RESTART_DELAY_MS") || "5000");
const WORKER_STABLE_SECONDS = int(getenv("TACHYON_WATCHDOG_STABLE_SECONDS") || "120");

let as_string = common.as_string;
let shell_quote = common.shell_quote;
let command_from_args = common.command_from_args;
let command_status = common.command_status;
let command_success_from_args = common.command_success_from_args;

function log_message(message, level) {
    let priority = 6;
    let lvl = as_string(level || "info");
    if (lvl == "warn" || lvl == "warning") {
        priority = 4;
    } else if (lvl == "err" || lvl == "error" || lvl == "fatal") {
        priority = 3;
    } else if (lvl == "debug") {
        priority = 7;
    }

    let kmsg = fs.open("/dev/kmsg", "w");
    if (kmsg) {
        kmsg.write(sprintf("<%d>tachyon: [%s] Watchdog: %s\n", priority, lvl, as_string(message)));
        kmsg.close();
    } else {
        command_success_from_args([ "logger", "-t", "tachyon", "[" + lvl + "] Watchdog: " + as_string(message) ]);
    }
}

function process_running(pid) {
    if (match(as_string(pid), /^[0-9]+$/) == null)
        return false;
    return fs.stat("/proc/" + pid) != null;
}

function trim_worker_err_file() {
    let max_bytes = WORKER_ERR_MAX_BYTES > 0 ? WORKER_ERR_MAX_BYTES : 65536;
    let keep_bytes = WORKER_ERR_KEEP_BYTES > 0 ? WORKER_ERR_KEEP_BYTES : 16384;
    if (keep_bytes > max_bytes)
        keep_bytes = max_bytes;
    let st = fs.stat(WORKER_ERR_FILE);
    if (st == null || st.type != "file" || st.size <= max_bytes)
        return false;
    let f = fs.open(WORKER_ERR_FILE, "r");
    if (!f)
        return false;
    f.seek(-keep_bytes, 2);
    let tail = f.read(keep_bytes);
    f.close();
    if (tail == null)
        return false;
    let nl = index(tail, "\n");
    if (nl >= 0 && nl + 1 < length(tail))
        tail = substr(tail, nl + 1);
    return fs.writefile(WORKER_ERR_FILE, tail) != null;
}

function last_worker_error() {
    trim_worker_err_file();
    let raw = trim(as_string(fs.readfile(WORKER_ERR_FILE) || ""));
    if (raw == "")
        return "";
    let lines = split(raw, "\n");
    for (let i = length(lines) - 1; i >= 0; i--) {
        let line = trim(as_string(lines[i] || ""));
        if (line != "")
            return " [" + substr(line, 0, 180) + "]";
    }
    return "";
}

function supervise() {
    log_message("Watchdog supervisor started", "info");

    let early_deaths = 0;
    let force_legacy = false;

    while (true) {
        fs.writefile(WORKER_ERR_FILE, "");
        let spawn = (force_legacy ? "TACHYON_WATCHDOG_LEGACY=1 " : "") +
            command_from_args([ "ucode", "-L", LIB_DIR, WORKER_UC, "worker" ]);
        command_status(common.background_command_with_pid(spawn, ">>" + shell_quote(WORKER_ERR_FILE), ">" + shell_quote(PID_FILE)));

        let started = time();
        while (true) {
            let pid = trim(fs.readfile(PID_FILE) || "");
            if (pid == "" || !process_running(pid))
                break;
            trim_worker_err_file();
            sleep(1000);
        }

        let lived = time() - started;
        let err_detail = last_worker_error();
        if (lived >= WORKER_STABLE_SECONDS) {
            early_deaths = 0;
            log_message("Watchdog worker exited after " + lived + "s; respawning" + err_detail, "warn");
        } else {
            early_deaths++;
            if (early_deaths >= 2 && !force_legacy) {
                force_legacy = true;
                log_message("Watchdog worker exited after " + lived + "s (early exit " +
                    early_deaths + "); respawning in legacy loop mode (uloop disabled)" + err_detail, "err");
            } else {
                log_message("Watchdog worker exited after " + lived + "s (early exit " +
                    early_deaths + "); respawning" + err_detail, "warn");
            }
        }
        sleep(WORKER_RESTART_DELAY_MS);
    }
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null) {
    return { supervise, trim_worker_err_file };
}

exit(supervise());
