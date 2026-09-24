#!/usr/bin/env ucode
//
// Unified process execution layer.
//
// Every process spawn in Tachyon should route through this module instead of
// calling system(), fs.popen(), or hand-rolling background_command strings.
//
// Benefits:
//   - Single place for FD cleanup, timeout enforcement, process identity
//   - Eliminates the class of bugs where a busybox tool (pkill) is missing
//     and the error is swallowed by 2>/dev/null || true
//   - Process identity (PID + starttime + boot_id) prevents PID-recycling bugs
//   - Every spawn closes inherited descriptors through close_inherited_fds()
//
// The module is deliberately low-level: no UCI, no nft, no sing-box knowledge.
// Higher-level abstractions (jobs, transactions) build on top of this.

let fs = require("fs");
let common = require("core.common");
let process_identity = require("core.process");

let as_string = common.as_string;
let shell_quote = common.shell_quote;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const PROC_SELF_FD = "/proc/self/fd";

// ---------------------------------------------------------------------------
// FD cleanup prologue (ported from common.uc, kept here as the canonical copy)
// ---------------------------------------------------------------------------

// Shell prologue that closes every descriptor a background spawn would inherit.
// See core/common.uc for the full rationale. This is the single canonical
// implementation; common.close_inherited_fds() delegates here.
function close_inherited_fds() {
    return "if ( eval \"exec 10<&-\" ) 2>/dev/null; then __tfd=1048576; else __tfd=9; fi; " +
        "for f in /proc/self/fd/*; do i=${f##*/}; case $i in 0|1|2) continue;; esac; " +
        "[ \"$i\" -le $__tfd ] 2>/dev/null || continue; " +
        "eval \"exec $i<&-\" 2>/dev/null || true; done; ";
}

// ---------------------------------------------------------------------------
// Process identity (delegated to core/process.uc)
// ---------------------------------------------------------------------------

// boot_id, process_starttime, make_identity, identity_matches are now provided
// by core.process. We re-export them here for backward compatibility.

function boot_id() { return process_identity.boot_id(); }
function process_starttime(pid) { return process_identity.process_starttime(pid); }
function make_identity(pid, command_name) { return process_identity.make_identity(pid, command_name); }
function identity_matches(identity, pid) { return process_identity.identity_matches(identity, pid); }

// ---------------------------------------------------------------------------
// Shell command building
// ---------------------------------------------------------------------------

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function command_env(assignments) {
    let parts = [];
    for (let name, value in assignments)
        push(parts, name + "=" + shell_quote(value));
    return join(" ", parts);
}

function command_status_from_args(args) {
    let status = int(system(command_from_args(args)));
    if (status == -1)
        return 255;
    let signal = status & 127;
    if (signal != 0)
        return 128 + signal;
    return (status >> 8) & 255;
}

function command_success_from_args(args) {
    return command_status_from_args(args) == 0;
}

// ---------------------------------------------------------------------------
// Timeout prefix detection (cached)
// ---------------------------------------------------------------------------

let _timeout_prefix = null;

function get_timeout_prefix() {
    if (_timeout_prefix != null)
        return _timeout_prefix;

    if (command_status_from_args([ "timeout", "-k", "1", "1", "/bin/true" ]) == 0)
        _timeout_prefix = [ "timeout", "-k", "5" ];
    else if (command_status_from_args([ "timeout", "1", "/bin/true" ]) == 0)
        _timeout_prefix = [ "timeout" ];
    else if (command_status_from_args([ "timeout", "-t", "1", "/bin/true" ]) == 0)
        _timeout_prefix = [ "timeout", "-t" ];
    else
        _timeout_prefix = [];

    return _timeout_prefix;
}

// ---------------------------------------------------------------------------
// Synchronous execution
// ---------------------------------------------------------------------------

// Synchronous execution. Returns { status, output }.
//
// options:
//   timeout  — seconds before SIGKILL (default: 30)
//   capture  — if true, capture stdout (default: true)
//   env      — object of environment variable overrides
//   argv     — command arguments (array)
//   command  — raw shell command string (alternative to argv)
function run(opts) {
    let args = opts.argv || [];
    let raw_command = as_string(opts.command || "");
    let do_capture = opts.capture !== false;
    let timeout_s = int(opts.timeout || 30);

    let cmd;
    if (raw_command != "") {
        cmd = raw_command;
    } else if (length(args) > 0) {
        cmd = command_from_args(args);
    } else {
        return { status: 0, output: "" };
    }

    // Apply environment overrides
    let env = opts.env;
    if (type(env) == "object" && length(keys(env)) > 0) {
        cmd = command_env(env) + " " + cmd;
    }

    // Apply timeout
    if (timeout_s > 0) {
        let prefix = get_timeout_prefix();
        if (length(prefix) > 0) {
            cmd = join(" ", prefix) + " " + as_string(timeout_s) + " sh -c " + shell_quote(cmd);
        }
    }

    if (do_capture) {
        let pipe = fs.popen(cmd + " 2>/dev/null", "r");
        if (!pipe)
            return { status: 255, output: "" };

        let output = as_string(pipe.read("all") || "");
        let raw_status = pipe.close();

        let status;
        if (raw_status == -1)
            status = 255;
        else {
            let signal = raw_status & 127;
            status = signal != 0 ? 128 + signal : (raw_status >> 8) & 255;
        }
        return { status: status, output: trim(output) };
    }

    let status = int(system(cmd));
    if (status == -1)
        return { status: 255, output: "" };
    let signal = status & 127;
    if (signal != 0)
        return { status: 128 + signal, output: "" };
    return { status: (status >> 8) & 255, output: "" };
}

// Convenience: run and return only the exit status (0 = success).
function run_status(opts) {
    return run({ ...opts, capture: false }).status;
}

// Convenience: run and return true if exit status is 0.
function run_success(opts) {
    return run_status(opts) == 0;
}

// Convenience: run and return stdout as a string. Non-zero exit is not an error;
// callers that care about errors should use run() directly.
function run_output(opts) {
    return run({ ...opts, capture: true }).output;
}

// Split any leading VAR=value assignments off the front of a command.
// Must be defined before run_background which calls it.
function split_leading_assignments(command) {
    let rest = trim(as_string(command));
    let assignments = "";

    while (true) {
        let matched = match(rest, /^([A-Za-z_][A-Za-z0-9_]*=[^ \t]*)[ \t]+/);
        if (matched) {
            assignments += matched[1] + " ";
            rest = substr(rest, length(matched[0]));
            continue;
        }
        let cd_match = match(rest, /^(cd[ \t]+[^&;]+[ \t]*&&[ \t]*)/);
        if (cd_match) {
            assignments += cd_match[1];
            rest = substr(rest, length(cd_match[0]));
            continue;
        }
        break;
    }

    return { assignments: assignments, command: rest };
}

// ---------------------------------------------------------------------------
// Background execution
// ---------------------------------------------------------------------------

// Launch a command in the background. Returns an identity object that can be
// used with is_alive(), kill(), and wait().
//
// options:
//   argv     — command arguments (array)
//   command  — raw shell command string (alternative to argv)
//   stdout   — redirect path for stdout (default: /dev/null)
//   stderr   — redirect path for stderr (default: same as stdout)
//   pid_file — write PID to this file
//   env      — object of environment variable overrides
//   name     — label for the identity (default: argv[0] basename)
function run_background(opts) {
    let args = opts.argv || [];
    let raw_command = as_string(opts.command || "");
    let stdout_redirect = as_string(opts.stdout || "/dev/null");
    let stderr_redirect = as_string(opts.stderr || stdout_redirect);
    let pid_file = as_string(opts.pid_file || "");
    let name = as_string(opts.name || (length(args) > 0 ? args[0] : ""));

    let cmd;
    if (raw_command != "") {
        cmd = raw_command;
    } else if (length(args) > 0) {
        cmd = command_from_args(args);
    } else {
        return { pid: "0", identity: null };
    }

    // Apply environment overrides: split VAR=value off the front for exec
    let env = opts.env;
    let env_prefix = "";
    if (type(env) == "object" && length(keys(env)) > 0) {
        env_prefix = command_env(env) + " ";
    }

    // Build the background spawn shell fragment
    let split = split_leading_assignments(env_prefix + cmd);
    let spawn = "{ " + close_inherited_fds() + split.assignments + "exec " + split.command +
        "; } </dev/null >/dev/null 2>&1 & echo $!";
    if (pid_file != "")
        spawn += " " + shell_quote(pid_file);

    // We need to capture the PID from the background spawn. Use popen to run
    // the shell fragment and read the PID from stdout.
    let pipe = fs.popen(spawn, "r");
    if (!pipe)
        return { pid: "0", identity: null };

    let pid_output = trim(as_string(pipe.read("line") || ""));
    pipe.close();

    let pid = pid_output;
    if (pid_file != "" && pid == "") {
        // PID was written to the file by the shell; read it back
        pid = trim(as_string(fs.readfile(pid_file) || ""));
    }

    if (match(pid, /^[0-9]+$/) == null)
        pid = "0";

    let identity = make_identity(pid, name);
    return { pid: pid, identity: identity };
}

// ---------------------------------------------------------------------------
// Process management
// ---------------------------------------------------------------------------

// Check if a process is alive. Uses kill -0 which does not signal but checks
// permission / existence.
function is_alive(pid) { return process_identity.pid_alive_raw(pid); }

// Check if an identity is still the same live process.
function identity_alive(identity) { return process_identity.identity_alive(identity); }

// Kill a process by PID. Sends SIGTERM first, then SIGKILL after a grace period.
function kill_process(pid, grace_seconds) {
    pid = as_string(pid);
    grace_seconds = int(grace_seconds || 3);

    if (match(pid, /^[0-9]+$/) == null || !is_alive(pid))
        return false;

    // SIGTERM
    command_success_from_args([ "kill", pid ]);

    // Wait for graceful exit
    let waited = 0;
    while (waited < grace_seconds && is_alive(pid)) {
        system("sleep 1");
        waited++;
    }

    // SIGKILL if still alive
    if (is_alive(pid)) {
        command_success_from_args([ "kill", "-9", pid ]);
        system("sleep 0.2");
    }

    return !is_alive(pid);
}

// Kill a process tree (parent + children). Uses the process group approach.
function kill_tree(pid, grace_seconds) {
    pid = as_string(pid);
    if (match(pid, /^[0-9]+$/) == null || !is_alive(pid))
        return false;

    // Send SIGTERM to process group
    command_success_from_args([ "kill", "--", "-" + pid ]);

    let grace = int(grace_seconds || 3);
    let waited = 0;
    while (waited < grace && is_alive(pid)) {
        system("sleep 1");
        waited++;
    }

    // SIGKILL if still alive
    if (is_alive(pid)) {
        command_success_from_args([ "kill", "-9", "--", "-" + pid ]);
        system("sleep 0.2");
    }

    return !is_alive(pid);
}

// Kill a process described by an identity object.
function kill_identity(identity, grace_seconds) {
    if (type(identity) != "object" || identity.pid == null)
        return false;
    return kill_process(identity.pid, grace_seconds);
}

// ---------------------------------------------------------------------------
// Bounded command (timeout wrapper)
// ---------------------------------------------------------------------------

// Wrap a command string with a timeout. Used for inline shell commands where
// argv decomposition is impractical.
function bounded_command(command, seconds) {
    seconds = as_string(seconds || "30");
    let prefix = get_timeout_prefix();
    if (length(prefix) == 0) {
        // Fallback: background the command, sleep, then kill
        return "sh -c " + shell_quote(
            "(" + as_string(command) + ") & __p=$!; " +
            "( sleep " + seconds + "; kill -9 $__p 2>/dev/null || true ) & __w=$!; " +
            "wait $__p 2>/dev/null; __rc=$?; kill -9 $__w 2>/dev/null || true; " +
            "wait $__w 2>/dev/null || true; exit $__rc"
        );
    }
    return join(" ", prefix) + " " + seconds + " sh -c " + shell_quote(as_string(command));
}

// ---------------------------------------------------------------------------
// Module exports
// ---------------------------------------------------------------------------

function module_exports() {
    return {
        // Process identity
        boot_id,
        process_starttime,
        make_identity,
        identity_matches,
        identity_alive,

        // FD cleanup
        close_inherited_fds,

        // Shell building
        command_from_args,
        command_env,
        command_status_from_args,
        command_success_from_args,

        // Synchronous execution
        run,
        run_status,
        run_success,
        run_output,

        // Background execution
        run_background,
        split_leading_assignments,

        // Process management
        is_alive,
        kill_process,
        kill_tree,
        kill_identity,

        // Timeout
        bounded_command,
        get_timeout_prefix,

        // Backwards-compatible aliases for callers that haven't migrated yet
        command_status: function(command) {
            let r = run({ command: command, capture: false });
            return r.status;
        },
        command_success: function(command) {
            return run_status({ command: command }) == 0;
        },
        command_capture: function(command) {
            return run({ command: command, capture: true });
        },
        command_output: function(command) {
            return run_output({ command: command });
        },
        command_output_from_args: function(args) {
            return run_output({ argv: args });
        },
        background_command: function(command) {
            return "{ " + close_inherited_fds() + as_string(command) + "; } </dev/null >/dev/null 2>&1 &";
        },
        background_command_with_pid: function(command, stdout_redirect, pid_sink) {
            let redirect = as_string(stdout_redirect || ">/dev/null");
            let sink = as_string(pid_sink);
            let split = split_leading_assignments(command);
            return "{ " + close_inherited_fds() + split.assignments + "exec " + split.command +
                "; } </dev/null " + redirect + " 2>&1 & echo $!" + (sink != "" ? " " + sink : "");
        },
        background_pipeline_with_pid: function(command, pid_sink) {
            let sink = as_string(pid_sink);
            return "{ " + close_inherited_fds() + as_string(command) +
                "; } </dev/null >/dev/null 2>&1 & echo $!" + (sink != "" ? " " + sink : "");
        },
        kill_matching_command: common.kill_matching_command,
        kill_orphaned_logread: common.kill_orphaned_logread
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

let mode = ARGV[0] || "";

if (mode == "selftest") {
    let pass = 0;
    let fail = 0;

    function assert(cond, msg) {
        if (cond) { pass++; }
        else { fail++; print("FAIL: " + msg + "\n"); }
    }

    // Test 1: boot_id is read
    assert(boot_id() != null && boot_id() != "", "boot_id should be non-empty");

    // Test 2: run with echo
    let r = run({ argv: ["/bin/echo", "hello"], timeout: 5 });
    assert(r.status == 0, "echo should return 0");
    assert(r.output == "hello", "echo output should be 'hello'");

    // Test 3: run_status with false
    let s = run_status({ argv: ["/bin/false"], timeout: 5 });
    assert(s != 0, "false should return non-zero");

    // Test 4: run_success with true
    assert(run_success({ argv: ["/bin/true"], timeout: 5 }), "true should succeed");

    // Test 5: run_output
    let o = run_output({ argv: ["/bin/echo", "test123"], timeout: 5 });
    assert(o == "test123", "run_output should capture stdout");

    // Test 6: is_alive with current process (should always be alive)
    let self_pid = null;
    let self_stat = trim(as_string(fs.readfile("/proc/self/stat") || ""));
    for (let field in split(self_stat, " ")) {
        self_pid = field;
        break;
    }
    assert(self_pid != null, "should read own PID from /proc/self/stat");
    assert(is_alive(self_pid), "current process should be alive");
    assert(!is_alive("999999"), "nonexistent PID should not be alive");

    // Test 7: make_identity
    let self_st = process_starttime(self_pid);
    let id = make_identity(self_pid, "self-test");
    assert(id.pid == self_pid, "identity pid should match");
    assert(id.command == "self-test", "identity command should match");
    assert(id.boot_id == boot_id(), "identity boot_id should match current");
    assert(id.starttime == self_st, "identity starttime should match");

    // Test 8: identity_matches
    assert(identity_matches(id, self_pid), "identity should match self");
    assert(!identity_matches(id, "999999"), "identity should not match nonexistent PID");

    // Test 9: kill_process on nonexistent is safe
    assert(!kill_process("999999"), "kill nonexistent should return false");

    // Test 10: split_leading_assignments
    let s1 = split_leading_assignments("FOO=bar BAZ=qux echo hello");
    assert(s1.assignments == "FOO=bar BAZ=qux ", "assignments should be extracted");
    assert(s1.command == "echo hello", "command should remain");

    print("exec.uc selftest: " + pass + " passed, " + fail + " failed\n");
    exit(fail > 0 ? 1 : 0);
}
else if (mode == "boot-id") {
    print(boot_id() + "\n");
}
else if (mode == "starttime") {
    if (ARGV[1] == null) {
        warn("Usage: core/exec.uc starttime <pid>\n");
        exit(1);
    }
    let st = process_starttime(ARGV[1]);
    if (st != null)
        print(st + "\n");
    else
        exit(1);
}
else {
    warn("Usage: core/exec.uc <selftest|boot-id|starttime> ...\n");
    exit(1);
}
