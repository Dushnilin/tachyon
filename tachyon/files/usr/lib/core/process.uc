#!/usr/bin/env ucode
//
// Unified process identity module.
//
// Provides stable process identification that survives PID recycling:
//   - PID + starttime (from /proc/PID/stat field 22)
//   - boot_id (changes on every reboot)
//   - cmdline matching
//
// This module is the single source of truth for process liveness checks.
// Other modules (exec.uc, state.uc) delegate here instead of re-implementing.
//
// Benefits:
//   - Eliminates stale PID / PID recycling race conditions
//   - Single place for /proc parsing (no ps, no pidof)
//   - Boot epoch detection prevents cross-reboot PID confusion

let fs = require("fs");
let common = require("core.common");

let as_string = common.as_string;
let shell_quote = common.shell_quote;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const PROC_STAT_FORMAT = "/proc/%s/stat";
const PROC_CMDLINE_FORMAT = "/proc/%s/cmdline";
const PROC_EXE_FORMAT = "/proc/%s/exe";
const PROC_COMM_FORMAT = "/proc/%s/comm";
const BOOT_ID_PATH = "/proc/sys/kernel/random/boot_id";

// Patterns that identify Tachyon-managed processes in /proc/PID/cmdline
const TACHYON_CMDLINE_PATTERN = /ucode|tachyon|sh|sing-box/;

// ---------------------------------------------------------------------------
// Boot ID
// ---------------------------------------------------------------------------

let _cached_boot_id = null;

// Read the boot_id once per interpreter lifetime. The boot_id changes on every
// reboot, so it acts as an epoch marker: a PID that survived a reboot is
// definitively stale even if Linux recycled the number.
function boot_id() {
    if (_cached_boot_id != null)
        return _cached_boot_id;
    let raw = trim(as_string(fs.readfile(BOOT_ID_PATH) || ""));
    _cached_boot_id = raw != "" ? raw : "unknown";
    return _cached_boot_id;
}

// ---------------------------------------------------------------------------
// /proc parsing
// ---------------------------------------------------------------------------

// Read /proc/PID/stat field 22 (starttime, clock ticks since boot). This is
// stable across PID recycling: two different processes that happen to share a
// PID will have different start times. Returns null if the process does not
// exist or the field cannot be read.
function process_starttime(pid) {
    pid = as_string(pid);
    if (match(pid, /^[0-9]+$/) == null)
        return null;
    let path = sprintf(PROC_STAT_FORMAT, pid);
    let data = trim(as_string(fs.readfile(path) || ""));
    if (data == "")
        return null;
    // Field 22 is after the closing paren of the command name. The command
    // name itself may contain spaces and parens, so we split from the right.
    let rp = rindex(data, ") ");
    if (rp < 0)
        return null;
    let fields = split(substr(data, rp + 2), " ");
    // starttime is field 22 overall, which is index 19 after the closing paren
    // (fields 3-22 in 1-indexed = fields 0-19 in 0-indexed after the split)
    if (length(fields) < 20)
        return null;
    return as_string(fields[19]);
}

// Alias: process_start_ticks is the same as process_starttime
// (reads field 22 from /proc/PID/stat)
function process_start_ticks_from_pid(pid) {
    return process_starttime(pid);
}

// Read starttime from raw /proc/PID/stat content (for callers that already
// have the stat content cached).
function process_start_ticks(stat) {
    stat = as_string(stat);
    let marker = index(stat, ") ");
    if (marker < 0)
        return null;

    let fields = split(trim(substr(stat, marker + 2)), /[ \t\r\n]+/);
    if (length(fields) < 20)
        return null;

    let start_ticks = fields[19];
    if (match(start_ticks, /^[0-9]+$/) == null)
        return null;

    return int(start_ticks);
}

// ---------------------------------------------------------------------------
// Process age calculation
// ---------------------------------------------------------------------------

// Calculate age in seconds from two tick values (start_ticks and current_ticks).
// Uses 100 Hz tick assumption (standard for Linux).
function process_age_seconds_from_ticks(start_ticks, current_ticks) {
    start_ticks = as_string(start_ticks);
    current_ticks = as_string(current_ticks);
    if (match(start_ticks, /^[0-9]+$/) == null || match(current_ticks, /^[0-9]+$/) == null)
        return null;

    start_ticks = int(start_ticks);
    current_ticks = int(current_ticks);
    if (current_ticks < start_ticks)
        return null;

    return int((current_ticks - start_ticks) / 100);
}

// Calculate age in seconds for a given PID. Returns null if PID doesn't exist.
function process_age_seconds(pid) {
    pid = as_string(pid);
    if (match(pid, /^[0-9]+$/) == null)
        return null;

    let start_ticks = process_start_ticks_from_pid(pid);
    if (start_ticks == null)
        return null;

    // Read current ticks from self
    let self_stat = trim(as_string(fs.readfile("/proc/self/stat") || ""));
    let current_ticks = process_start_ticks(self_stat);
    if (current_ticks == null)
        return null;

    return process_age_seconds_from_ticks(start_ticks, current_ticks);
}

// ---------------------------------------------------------------------------
// Process liveness
// ---------------------------------------------------------------------------

// Check if a PID is alive using kill -0 (does not signal, just checks existence).
function pid_alive_raw(pid) {
    pid = as_string(pid);
    if (match(pid, /^[0-9]+$/) == null)
        return false;
    let status = int(system("kill -0 " + shell_quote(pid) + " 2>/dev/null"));
    if (status == -1)
        return false;
    let signal = status & 127;
    if (signal != 0)
        return false;
    return ((status >> 8) & 255) == 0;
}

// Check if a PID is alive AND belongs to a Tachyon-managed process.
// This is the legacy pid_alive() from state.uc that also checks cmdline.
function is_tachyon_process(pid) {
    pid = as_string(pid);
    if (!pid_alive_raw(pid))
        return false;
    let cmd = fs.readfile(sprintf(PROC_CMDLINE_FORMAT, pid));
    if (cmd != null && match(cmd, TACHYON_CMDLINE_PATTERN) == null)
        return false;
    return true;
}

// Check if a PID is a sing-box process (by /proc/PID/exe or /proc/PID/comm).
function is_sing_box(pid) {
    pid = as_string(pid);
    if (match(pid, /^[0-9]+$/) == null)
        return false;

    let exe = fs.readlink(sprintf(PROC_EXE_FORMAT, pid));
    if (exe != null && exe != "") {
        let slash = rindex(exe, "/");
        let basename = slash >= 0 ? substr(exe, slash + 1) : exe;
        if (basename == "sing-box")
            return true;
    }

    let comm = trim(as_string(fs.readfile(sprintf(PROC_COMM_FORMAT, pid)) || ""));
    if (comm == "sing-box")
        return true;

    return false;
}

// ---------------------------------------------------------------------------
// Process identity
// ---------------------------------------------------------------------------

// Build a process identity object. This is the portable handle that replaces
// bare PIDs throughout the codebase.
function make_identity(pid, command_name) {
    return {
        pid: as_string(pid),
        starttime: process_starttime(pid),
        boot_id: boot_id(),
        command: as_string(command_name || ""),
        created_at: time()
    };
}

// Verify that a PID still belongs to the same process we launched. This guards
// against PID recycling: Linux may assign the same number to an unrelated
// process after our worker dies.
function identity_matches(identity, pid) {
    if (type(identity) != "object")
        return false;
    let current_pid = as_string(pid || identity.pid);
    if (match(current_pid, /^[0-9]+$/) == null)
        return false;

    // Fast path: boot_id changed → everything is stale
    if (identity.boot_id != null && identity.boot_id != boot_id())
        return false;

    // Check that the PID is alive
    if (!pid_alive_raw(current_pid))
        return false;

    // Check starttime matches (guards against PID recycling)
    if (identity.starttime != null) {
        let current_starttime = process_starttime(current_pid);
        if (current_starttime == null || current_starttime != identity.starttime)
            return false;
    }

    return true;
}

// Check if an identity is still the same live process.
function identity_alive(identity) {
    return identity_matches(identity, identity.pid);
}

// ---------------------------------------------------------------------------
// Module exports
// ---------------------------------------------------------------------------

function module_exports() {
    return {
        // Boot ID
        boot_id,

        // Process starttime (field 22 from /proc/PID/stat)
        process_starttime,
        process_start_ticks,
        process_start_ticks_from_pid,

        // Age calculation
        process_age_seconds_from_ticks,
        process_age_seconds,

        // Liveness
        pid_alive_raw,
        is_tachyon_process,
        is_sing_box,

        // Identity
        make_identity,
        identity_matches,
        identity_alive
    };
}

if (sourcepath(1) != null && sourcepath(1) != "")
    return module_exports();

// ---------------------------------------------------------------------------
// CLI / selftest
// ---------------------------------------------------------------------------

let mode = ARGV[0] || "";

let _test_pass = 0;
let _test_fail = 0;

function _test_assert(cond, msg) {
    if (cond) { _test_pass++; }
    else { _test_fail++; print("FAIL: " + msg + "\n"); }
}

if (mode == "selftest") {
    _test_pass = 0;
    _test_fail = 0;

    // Test 1: boot_id is read and non-empty
    _test_assert(boot_id() != null && boot_id() != "", "boot_id should be non-empty");
    _test_assert(boot_id() == _cached_boot_id, "boot_id should be cached");

    // Test 2: process_starttime for current process
    let self_pid = null;
    let self_stat = trim(as_string(fs.readfile("/proc/self/stat") || ""));
    for (let field in split(self_stat, " ")) {
        self_pid = field;
        break;
    }
    _test_assert(self_pid != null, "should read own PID");
    let st = process_starttime(self_pid);
    _test_assert(st != null, "starttime for self should be readable");
    _test_assert(match(st, /^[0-9]+$/) != null, "starttime should be numeric");

    // Test 3: process_starttime for nonexistent PID
    _test_assert(process_starttime("999999") == null, "nonexistent PID should return null");
    _test_assert(process_starttime("abc") == null, "non-numeric PID should return null");
    _test_assert(process_starttime("") == null, "empty PID should return null");

    // Test 4: process_start_ticks from raw stat
    let ticks = process_start_ticks(self_stat);
    _test_assert(ticks != null, "process_start_ticks should parse /proc/self/stat");
    _test_assert(type(ticks) == "int", "process_start_ticks should return int");

    // Test 5: process_age_seconds
    let age = process_age_seconds(self_pid);
    _test_assert(age != null, "age of self should be readable");
    _test_assert(age >= 0, "age of self should be >= 0");

    // Test 6: process_age_seconds_from_ticks
    let age_from_ticks = process_age_seconds_from_ticks(ticks, ticks + 500);
    _test_assert(age_from_ticks == 5, "500 ticks at 100Hz should be 5 seconds");
    _test_assert(process_age_seconds_from_ticks(100, 50) == null, "backwards ticks should return null");

    // Test 7: pid_alive_raw
    _test_assert(pid_alive_raw(self_pid), "current process should be alive");
    _test_assert(!pid_alive_raw("999999"), "nonexistent PID should not be alive");
    _test_assert(!pid_alive_raw("abc"), "non-numeric PID should not be alive");

    // Test 8: is_tachyon_process (current ucode process has tachyon in cmdline when run via test)
    // This may or may not match depending on how the test is invoked, so just check it doesn't crash
    let _ = is_tachyon_process(self_pid);
    _test_assert(is_tachyon_process("999999") == false, "nonexistent PID is not tachyon process");

    // Test 9: make_identity
    let id = make_identity(self_pid, "self-test");
    _test_assert(id.pid == self_pid, "identity pid should match");
    _test_assert(id.command == "self-test", "identity command should match");
    _test_assert(id.boot_id == boot_id(), "identity boot_id should match current");
    _test_assert(id.starttime == st, "identity starttime should match");
    _test_assert(id.created_at != null, "identity created_at should be set");

    // Test 10: identity_matches
    _test_assert(identity_matches(id, self_pid), "identity should match self");
    _test_assert(!identity_matches(id, "999999"), "identity should not match nonexistent PID");
    _test_assert(!identity_matches(id, "abc"), "identity should not match non-numeric PID");
    _test_assert(!identity_matches("not_an_object", self_pid), "non-object identity should not match");

    // Test 11: identity_alive
    _test_assert(identity_alive(id), "identity should be alive");

    // Test 12: boot_id unchanged across calls
    let bid1 = boot_id();
    let bid2 = boot_id();
    _test_assert(bid1 == bid2, "boot_id should be stable");

    print("process.uc selftest: " + _test_pass + " passed, " + _test_fail + " failed\n");
    exit(_test_fail > 0 ? 1 : 0);
}
else if (mode == "boot-id") {
    print(boot_id() + "\n");
}
else if (mode == "starttime") {
    if (ARGV[1] == null) {
        warn("Usage: core/process.uc starttime <pid>\n");
        exit(1);
    }
    let result = process_starttime(ARGV[1]);
    if (result != null)
        print(result + "\n");
    else
        exit(1);
}
else if (mode == "age") {
    if (ARGV[1] == null) {
        warn("Usage: core/process.uc age <pid>\n");
        exit(1);
    }
    let result = process_age_seconds(ARGV[1]);
    if (result != null)
        print(result + "\n");
    else
        exit(1);
}
else if (mode == "alive") {
    if (ARGV[1] == null) {
        warn("Usage: core/process.uc alive <pid>\n");
        exit(1);
    }
    exit(pid_alive_raw(ARGV[1]) ? 0 : 1);
}
else {
    print("Usage: core/process.uc <selftest|boot-id|starttime|age|alive> ...\n");
    exit(1);
}
