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
const PROC_DIR_FORMAT = "/proc/%s";
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

    // Spawn a short-lived process to get "current" ticks — process_start_ticks
    // reads field 22 (starttime) from /proc/PID/stat, so the cat process's
    // starttime is approximately "now" in jiffies.
    let current_ticks = process_start_ticks(common.command_output_from_args([ "cat", "/proc/self/stat" ]));
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
    // Fast path: /proc needs no permission to stat the directory entry and
    // avoids forking a shell for `kill -0` on every liveness probe.
    if (fs.access(sprintf(PROC_DIR_FORMAT, pid), "f") == true)
        return true;
    if (fs.access("/proc/self", "f") == true)
        return false;
    return int(system("kill -0 " + shell_quote(pid) + " 2>/dev/null")) == 0;
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

// The core answers to `tachyon-core`. A router upgraded from the previous
// release can still have the old process or its `/usr/bin/sing-box` symlink
// running, so both names count as the engine here.
const CORE_PROCESS_NAMES = [ "tachyon-core", "sing-box" ];

// Service identity for the proxy core. Doctor, status, watchdog, lifecycle
// and every init-script generator read this instead of hardcoding the procd
// name, binary paths, pid files or UCI package. The init script's comm is
// the procd name (`tachyon-core`, 15 characters), so BusyBox `killall` of
// that name signals the script that is starting or stopping the daemon.
function core_contract() {
    return {
        procd_name: "tachyon-core",
        init_script: "/etc/init.d/tachyon-core",
        uci_package: "tachyon-core",
        pid_files: [
            "/var/run/tachyon-core.pid",
            "/var/run/tachyon-core/tachyon-core.pid",
            "/var/run/sing-box.pid",
            "/var/run/sing-box/sing-box.pid"
        ],
        binaries: [ "/usr/bin/tachyon-core", "/usr/bin/sing-box" ],
        comm_names: CORE_PROCESS_NAMES,
        workdir: "/usr/share/tachyon-core",
        config_file: "/etc/tachyon-core/config.json",
        log_file: "/tmp/tachyon-core/sing-box.log"
    };
}

function own_pid() {
    let stat = trim(as_string(fs.readfile("/proc/self/stat") || ""));
    let sp = index(stat, " ");
    if (sp <= 0)
        return "";
    return substr(stat, 0, sp);
}

function exe_basename(pid) {
    let exe = fs.readlink(sprintf(PROC_EXE_FORMAT, as_string(pid)));
    if (exe == null || exe == "")
        return "";
    exe = as_string(exe);
    let space = index(exe, " ");
    if (space >= 0)
        exe = substr(exe, 0, space);
    let slash = rindex(exe, "/");
    return slash >= 0 ? substr(exe, slash + 1) : exe;
}

// /etc/init.d/tachyon-core is a shell script whose comm is tachyon-core.
// Matching on comm alone treats that script as the daemon.
function is_core_initscript(pid) {
    pid = as_string(pid);
    if (match(pid, /^[0-9]+$/) == null)
        return false;
    let cmd = as_string(fs.readfile(sprintf(PROC_CMDLINE_FORMAT, pid)) || "");
    return index(cmd, core_contract().init_script) >= 0;
}

function core_daemon_pids() {
    let found = [];
    let directory = fs.opendir("/proc");
    if (!directory)
        return found;
    let entry;
    let self = own_pid();
    while ((entry = directory.read()) != null) {
        if (match(entry, /^[0-9]+$/) == null)
            continue;
        if (entry == self || is_core_initscript(entry))
            continue;
        if (index(CORE_PROCESS_NAMES, exe_basename(entry)) >= 0)
            push(found, entry);
    }
    directory.close();
    return found;
}

// Signal daemon binaries only. Never killall: that matches the init script.
function kill_core_daemons() {
    let killed = 0;
    for (let pid in core_daemon_pids()) {
        if (common.command_success_from_args([ "kill", "-9", pid ]))
            killed++;
    }
    return killed;
}

function init_script_kills_itself(text) {
    let name = core_contract().procd_name;
    for (let line in split(as_string(text), "\n")) {
        if (index(line, "killall") < 0)
            continue;
        if (match(line, regexp("(^|[^A-Za-z0-9_-])" + name + "([^A-Za-z0-9_-]|$)")) != null)
            return true;
    }
    return false;
}

// Single generator for /etc/init.d/tachyon-core. reset_log keeps the
// component-install variant that truncates the core log before procd starts.
function managed_core_init_script(marker, reset_log) {
    let contract = core_contract();
    marker = as_string(marker);
    if (marker == "")
        marker = "Tachyon managed sing-box service for binary variants";

    let primary = contract.binaries[0];
    let fallback = contract.binaries[1];
    let comms = contract.comm_names[0] + " " + contract.comm_names[1];
    let exe_case = "*/" + contract.comm_names[0] + "|*/" + contract.comm_names[1];
    let log_prep = "";
    if (reset_log)
        log_prep = "    mkdir -p /tmp/tachyon-core 2>/dev/null\n" +
            "    : > " + contract.log_file + " 2>/dev/null\n";

    return "#!/bin/sh /etc/rc.common\n" +
        "# " + marker + "\n\n" +
        "USE_PROCD=1\n" +
        "START=99\n" +
        "PROG=\"" + primary + "\"\n" +
        "[ -x \"$PROG\" ] || PROG=\"" + fallback + "\"\n\n" +
        "_kill_daemon_instances() {\n" +
        "    for p in $(pidof " + comms + " 2>/dev/null); do\n" +
        "        [ \"$p\" != \"$$\" ] || continue\n" +
        "        case \"$(readlink -f /proc/$p/exe 2>/dev/null)\" in\n" +
        "            " + exe_case + ") kill -9 \"$p\" 2>/dev/null || true ;;\n" +
        "        esac\n" +
        "    done\n" +
        "}\n\n" +
        "_has_running_daemon() {\n" +
        "    for p in $(pidof " + comms + " 2>/dev/null); do\n" +
        "        [ \"$p\" != \"$$\" ] || continue\n" +
        "        case \"$(readlink -f /proc/$p/exe 2>/dev/null)\" in\n" +
        "            " + exe_case + ") return 0 ;;\n" +
        "        esac\n" +
        "    done\n" +
        "    return 1\n" +
        "}\n\n" +
        "start_service() {\n" +
        "    [ -d /dev/net ] || mkdir -p /dev/net\n" +
        "    [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200 2>/dev/null || true\n" +
        "    modprobe tun 2>/dev/null || true\n" +
        "    modprobe inet_diag 2>/dev/null || true\n\n" +
        "    config_load \"" + contract.uci_package + "\"\n" +
        "    local enabled config_file working_directory\n" +
        "    local log_stderr\n\n" +
        "    config_get_bool enabled \"main\" \"enabled\" \"0\"\n" +
        "    [ \"$enabled\" -eq \"1\" ] || return 0\n\n" +
        "    [ -x \"$PROG\" ] || PROG=\"$(command -v " + contract.comm_names[0] + " 2>/dev/null || command -v " + contract.comm_names[1] + " 2>/dev/null || echo " + primary + ")\"\n" +
        "    config_get config_file \"main\" \"conffile\" \"" + contract.config_file + "\"\n" +
        "    config_get working_directory \"main\" \"workdir\" \"" + contract.workdir + "\"\n" +
        "    [ -d \"$working_directory\" ] || mkdir -p \"$working_directory\"\n" +
        "    config_get_bool log_stderr \"main\" \"log_stderr\" \"1\"\n\n" +
        "    local mem_limit_mb=\"0\"\n" +
        "    config_get mem_limit_mb \"main\" \"memory_limit_mb\" \"0\"\n" +
        "    if [ \"$mem_limit_mb\" = \"0\" ] || [ -z \"$mem_limit_mb\" ]; then\n" +
        "        mem_limit_mb=\"$(uci get tachyon.settings.memory_limit_mb 2>/dev/null || echo 0)\"\n" +
        "    fi\n\n" +
        "    local scale_pct=\"\"\n" +
        "    if [ -s \"/etc/tachyon/mem_scale\" ]; then\n" +
        "        scale_pct=\"$(awk -v s=\"$(cat /etc/tachyon/mem_scale 2>/dev/null)\" 'BEGIN { if (!s) exit; pct=int(s*100); if (pct < 20) pct=20; if (pct > 100) pct=100; print pct }')\"\n" +
        "    fi\n\n" +
        "    local gomemlimit=\"\"\n" +
        "    local mem_total_kb=\"$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)\"\n" +
        "    if [ \"$mem_limit_mb\" -gt 0 ] 2>/dev/null; then\n" +
        "        gomemlimit=\"$mem_limit_mb\"\n" +
        "    elif [ \"$mem_total_kb\" -gt 0 ]; then\n" +
        "        if [ \"$mem_total_kb\" -le 524288 ] || { [ -n \"$scale_pct\" ] && [ \"$scale_pct\" -lt 100 ]; }; then\n" +
        "            gomemlimit=$(( mem_total_kb / 1024 * 50 / 100 ))\n" +
        "            [ \"$gomemlimit\" -lt 24 ] && gomemlimit=24\n" +
        "        fi\n" +
        "    fi\n\n" +
        "    if [ -n \"$gomemlimit\" ] && [ \"$gomemlimit\" -gt 0 ] 2>/dev/null; then\n" +
        "        if [ -n \"$scale_pct\" ] && [ \"$scale_pct\" -lt 100 ]; then\n" +
        "            gomemlimit=$(( gomemlimit * scale_pct / 100 ))\n" +
        "            [ \"$gomemlimit\" -lt 16 ] && gomemlimit=16\n" +
        "        fi\n" +
        "    fi\n\n" +
        log_prep +
        "    _kill_daemon_instances\n\n" +
    "    procd_open_instance\n" +
        "    procd_set_param command \"$PROG\" run -c \"$config_file\" -D \"$working_directory\"\n" +
        "    procd_set_param stderr \"$log_stderr\"\n" +
        "    procd_set_param limits core=\"0\"\n" +
        "    procd_set_param limits nofile=\"65535 65535\"\n" +
        "    if [ -n \"$gomemlimit\" ] && [ \"$gomemlimit\" -gt 0 ] 2>/dev/null; then\n" +
        "        procd_set_param env GODEBUG=\"madvdontneed=1\" GOGC=\"50\" TACHYON_RULESET_SOFT_START=\"1\" GOMEMLIMIT=\"${gomemlimit}MiB\"\n" +
        "    else\n" +
        "        procd_set_param env GODEBUG=\"madvdontneed=1\" GOGC=\"50\" TACHYON_RULESET_SOFT_START=\"1\"\n" +
        "    fi\n" +
        "    procd_set_param term_timeout 15\n" +
        "    procd_set_param respawn ${respawn_threshold:-3600} ${respawn_timeout:-5} ${respawn_retry:-5}\n" +
        "    procd_close_instance\n" +
        "}\n\n" +
        "stop_service() {\n" +
        "    local i=0\n" +
        "    while [ \"$i\" -lt 20 ]; do\n" +
        "        _has_running_daemon || return 0\n" +
        "        sleep 0.1 2>/dev/null || sleep 1\n" +
        "        i=$(( i + 1 ))\n" +
        "    done\n" +
        "    _kill_daemon_instances\n" +
        "}\n\n" +
        "reload_service() {\n" +
        "    for p in $(pidof " + comms + " 2>/dev/null); do\n" +
        "        [ \"$p\" != \"$$\" ] || continue\n" +
        "        case \"$(readlink -f /proc/$p/exe 2>/dev/null)\" in\n" +
        "            " + exe_case + ")\n" +
        "                if ucode -L /usr/lib/tachyon /usr/lib/tachyon/service/state.uc sighup-core-runtime \"$p\" >/dev/null 2>&1; then\n" +
        "                    return 0\n" +
        "                fi\n" +
        "                break\n" +
        "                ;;\n" +
        "        esac\n" +
        "    done\n" +
        "    restart\n" +
        "}\n\n" +
        "service_triggers() {\n" +
        "    procd_add_reload_trigger \"" + contract.procd_name + "\"\n" +
        "}\n";
}

// Check if a PID is a proxy-core process (by /proc/PID/exe or /proc/PID/comm).
function is_sing_box(pid) {
    pid = as_string(pid);
    if (match(pid, /^[0-9]+$/) == null)
        return false;
    if (is_core_initscript(pid))
        return false;

    if (index(CORE_PROCESS_NAMES, exe_basename(pid)) >= 0)
        return true;

    let comm = trim(as_string(fs.readfile(sprintf(PROC_COMM_FORMAT, pid)) || ""));
    if (index(CORE_PROCESS_NAMES, comm) >= 0)
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

    // An identity without both markers cannot be verified, so it is not
    // trusted. This used to skip each check when the field was missing, which
    // quietly degraded the whole guard to "is that pid alive" - exactly the
    // PID-recycling hazard this module exists to stop. The reachable case is a
    // state file written by an older version, or a record lost to a partial
    // write: either way the job then looked alive forever.
    if (identity.boot_id == null || identity.starttime == null)
        return false;

    // Fast path: boot_id changed, so everything is stale
    if (identity.boot_id != boot_id())
        return false;

    // Check that the PID is alive
    if (!pid_alive_raw(current_pid))
        return false;

    // Check starttime matches (guards against PID recycling)
    let current_starttime = process_starttime(current_pid);
    if (current_starttime == null || current_starttime != identity.starttime)
        return false;

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
        core_contract,
        own_pid,
        exe_basename,
        is_core_initscript,
        core_daemon_pids,
        kill_core_daemons,
        init_script_kills_itself,
        managed_core_init_script,

        // Identity
        make_identity,
        identity_matches,
        identity_alive
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

// ---------------------------------------------------------------------------
// CLI / selftest — only runs when invoked directly, not via require()
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

    // Test 13: generated init never killall's its own comm
    let contract = core_contract();
    _test_assert(contract.procd_name == "tachyon-core", "procd name");
    _test_assert(contract.init_script == "/etc/init.d/tachyon-core", "init script path");
    let generated = managed_core_init_script("marker", false);
    let generated_log = managed_core_init_script("marker", true);
    _test_assert(index(generated, "killall") < 0, "generated init must not call killall");
    _test_assert(!init_script_kills_itself(generated), "generated init must not kill itself");
    _test_assert(init_script_kills_itself("killall -q -9 tachyon-core\n"), "detector flags killall of the init comm");
    _test_assert(index(generated, "_kill_daemon_instances") >= 0, "safe killer is present");
    _test_assert(index(generated_log, contract.log_file) >= 0, "reset-log variant truncates the core log");
    _test_assert(index(generated, contract.log_file) < 0, "plain variant leaves the core log alone");

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
else if (mode == "init-script") {
    print(managed_core_init_script(ARGV[1] || "", ARGV[2] == "reset-log"));
}
else if (mode == "kills-itself") {
    if (ARGV[1] == null) {
        warn("Usage: core/process.uc kills-itself <file>\n");
        exit(1);
    }
    exit(init_script_kills_itself(fs.readfile(ARGV[1]) || "") ? 0 : 1);
}
else {
    print("Usage: core/process.uc <selftest|boot-id|starttime|age|alive|init-script|kills-itself> ...\n");
    exit(1);
}
