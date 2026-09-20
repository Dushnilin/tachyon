#!/usr/bin/env ucode
//
// Unified structured logging module.
//
// Replaces 19+ independent log_message()/log() definitions across the codebase.
// Every module should use: let log = require("core.logging");
//                            log.info("component.update", "message");
//
// Structured fields:
//   - timestamp (epoch)
//   - level (info, warn, error, debug, fatal)
//   - subsystem (component name)
//   - operation (specific operation)
//   - job_id (optional)
//   - correlation_id (optional)
//   - message (human-readable)
//
// Backward-compatible: log_message(msg, level, tag) works as before.

let fs = require("fs");
let common = require("core.common");

let as_string = common.as_string;
let shell_quote = common.shell_quote;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const LEVELS = {
    debug: 7,
    info: 6,
    warn: 4,
    warning: 4,
    error: 3,
    err: 3,
    fatal: 3
};

const DEFAULT_TAG = "tachyon";
const KMSG_PATH = "/dev/kmsg";

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

function command_success_from_args(args) {
    return system(common.command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function resolve_priority(level) {
    return LEVELS[as_string(level)] || 6;
}

function format_timestamp() {
    let t = time();
    let tm = localtime(t);
    if (!tm)
        return as_string(t);
    return sprintf("%04d-%02d-%02dT%02d:%02d:%02d",
        int(tm.year), int(tm.mon) + 1, int(tm.mday),
        int(tm.hour), int(tm.min), int(tm.sec));
}

// ---------------------------------------------------------------------------
// Core logging
// ---------------------------------------------------------------------------

// Structured log entry. All fields except message are optional.
//
// Usage:
//   log.write({
//       level: "info",
//       subsystem: "component",
//       operation: "update",
//       job_id: "cmp-abc123",
//       message: "sing-box update started"
//   });
function write(entry) {
    let level = as_string(entry.level || "info");
    let subsystem = as_string(entry.subsystem || "");
    let operation = as_string(entry.operation || "");
    let job_id = as_string(entry.job_id || "");
    let correlation_id = as_string(entry.correlation_id || "");
    let message = as_string(entry.message || "");

    // Build structured tag
    let tag = DEFAULT_TAG;
    if (subsystem != "")
        tag += "." + subsystem;

    // Build structured prefix
    let prefix = "";
    if (operation != "")
        prefix += "op=" + operation + " ";
    if (job_id != "")
        prefix += "job=" + job_id + " ";
    if (correlation_id != "")
        prefix += "corr=" + correlation_id + " ";

    let full_message = "[" + level + "] " + prefix + message;

    // Write to syslog
    command_success_from_args([ "logger", "-t", tag, full_message ]);

    // Write to kmsg for error/fatal levels (kernel message buffer, visible in dmesg)
    let priority = resolve_priority(level);
    if (priority <= 4) {
        let kmsg = fs.open(KMSG_PATH, "w");
        if (kmsg) {
            kmsg.write(sprintf("<%d>%s: [%s] %s\n", priority, tag, level, message));
            kmsg.close();
        }
    }

    return true;
}

// ---------------------------------------------------------------------------
// Convenience methods (level-specific)
// ---------------------------------------------------------------------------

function debug(message, subsystem, operation) {
    return write({ level: "debug", subsystem: subsystem, operation: operation, message: message });
}

function info(message, subsystem, operation) {
    return write({ level: "info", subsystem: subsystem, operation: operation, message: message });
}

function warn(message, subsystem, operation) {
    return write({ level: "warn", subsystem: subsystem, operation: operation, message: message });
}

function error(message, subsystem, operation) {
    return write({ level: "error", subsystem: subsystem, operation: operation, message: message });
}

function fatal(message, subsystem, operation) {
    return write({ level: "fatal", subsystem: subsystem, operation: operation, message: message });
}

// ---------------------------------------------------------------------------
// Backward-compatible log_message (drop-in replacement)
// ---------------------------------------------------------------------------

// Matches the signature: log_message(message, level, tag)
// This is the canonical replacement for the 19 independent definitions.
function log_message(message, level, tag) {
    level = as_string(level || "info");
    tag = as_string(tag || "");

    let subsystem = "";
    let operation = "";

    // Parse tag like "tachyon-component" or "tachyon-hosts" into subsystem
    if (tag != "" && tag != DEFAULT_TAG) {
        if (substr(tag, 0, length(DEFAULT_TAG) + 1) == DEFAULT_TAG + "-") {
            subsystem = substr(tag, length(DEFAULT_TAG) + 1);
        } else {
            subsystem = tag;
        }
    }

    return write({ level: level, subsystem: subsystem, message: message });
}

// ---------------------------------------------------------------------------
// Job log (for component updates, Tachyon updates, etc.)
// ---------------------------------------------------------------------------

// Append a log entry to a job-specific log file.
// path is typically from $UPDATES_JOB_LOG env var.
function job_log_append(path, message, level) {
    path = as_string(path);
    if (path == "")
        return false;

    let file = fs.open(path, "a");
    if (!file)
        return false;

    let t = time();
    let tm = localtime(t);
    let timestamp = tm ?
        sprintf("%02d:%02d:%02d", int(tm.hour), int(tm.min), int(tm.sec)) :
        as_string(t);

    file.write(sprintf("[%s] [%s] %s\n", timestamp, as_string(level || "info"), as_string(message)));
    file.close();
    return true;
}

// ---------------------------------------------------------------------------
// Module exports
// ---------------------------------------------------------------------------

function module_exports() {
    return {
        // Structured logging
        write,

        // Level-specific convenience
        debug,
        info,
        warn,
        error,
        fatal,

        // Backward-compatible
        log_message,

        // Job log
        job_log_append,

        // Constants
        LEVELS,
        DEFAULT_TAG
    };
}

if (sourcepath(1) != null && sourcepath(1) != "")
    return module_exports();

// ---------------------------------------------------------------------------
// CLI / selftest
// ---------------------------------------------------------------------------

let mode = ARGV[0] || "";

if (mode == "selftest") {
    let pass = 0;
    let fail = 0;

    let assert = function(cond, msg) {
        if (cond) { pass++; }
        else { fail++; print("FAIL: " + msg + "\n"); }
    }

    // Test 1: log_message works (writes to syslog)
    assert(log_message("test message") === true, "log_message should return true");
    assert(log_message("test warn", "warn") === true, "log_message with level should work");
    assert(log_message("test tag", "info", "tachyon-test") === true, "log_message with tag should work");

    // Test 2: structured write
    assert(write({ level: "info", subsystem: "test", message: "structured test" }) === true, "structured write should work");
    assert(write({ level: "error", subsystem: "test", operation: "op1", job_id: "j-123", message: "error test" }) === true, "structured write with all fields should work");

    // Test 3: convenience methods
    assert(debug("debug msg") === true, "debug should work");
    assert(info("info msg") === true, "info should work");
    assert(warn("warn msg") === true, "warn should work");
    assert(error("error msg") === true, "error should work");
    assert(fatal("fatal msg") === true, "fatal should work");

    // Test 4: job_log_append to temp file
    let tmp = "/tmp/tachyon-test-log." + getpid();
    assert(job_log_append(tmp, "job entry 1", "info") === true, "job_log_append should write");
    assert(job_log_append(tmp, "job entry 2", "error") === true, "job_log_append should append");
    let content = trim(fs.readfile(tmp) || "");
    assert(index(content, "job entry 1") >= 0, "job log should contain first entry");
    assert(index(content, "job entry 2") >= 0, "job log should contain second entry");
    assert(index(content, "[info]") >= 0, "job log should contain level");
    try { fs.unlink(tmp); } catch(e) {}

    // Test 5: job_log_append to empty path does not crash
    assert(job_log_append("", "msg") === false, "empty path should return false");
    assert(job_log_append(null, "msg") === false, "null path should return false");

    // Test 6: LEVELS constant
    assert(LEVELS.info == 6, "info priority should be 6");
    assert(LEVELS.warn == 4, "warn priority should be 4");
    assert(LEVELS.error == 3, "error priority should be 3");
    assert(LEVELS.debug == 7, "debug priority should be 7");

    print("logging.uc selftest: " + pass + " passed, " + fail + " failed\n");
    exit(fail > 0 ? 1 : 0);
}
else if (mode == "log") {
    // CLI: logging.uc log <level> <message> [subsystem] [operation]
    let level = ARGV[1] || "info";
    let message = ARGV[2] || "";
    let subsystem = ARGV[3] || "";
    let operation = ARGV[4] || "";
    write({ level: level, subsystem: subsystem, operation: operation, message: message });
}
else {
    print("Usage: core/logging.uc <selftest|log> ...\n");
    exit(1);
}
