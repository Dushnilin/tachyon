#!/usr/bin/env ucode

let fs = require("fs");

global.double = function(v) {
    if (v == null || v == "")
        return 0.0;
    return v * 1.0;
};

function as_string(value) {
    return value == null ? "" : "" + value;
}

function read_json_file(path) {
    let data = fs.readfile(path);
    if (data == null)
        return null;

    try {
        return json(data);
    }
    catch (e) {
        return null;
    }
}

function read_stdin() {
    let input = fs.open("/dev/stdin", "r");
    if (!input)
        return "";
    let data = input.read("all");
    input.close();
    return data == null ? "" : data;
}

function read_stdin_json() {
    let data = read_stdin();
    try {
        return json(data);
    }
    catch (e) {
        return null;
    }
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function write_compact_string_array(values) {
    print("[");
    for (let i = 0; i < length(values); i++) {
        if (i > 0)
            print(",");
        print(sprintf("%J", as_string(values[i])));
    }
    print("]\n");
}

function csv_to_json_array(value) {
    value = as_string(value);
    write_compact_string_array(value == "" ? [] : split(value, ","));
}

function write_json_file(path, value) {
    path = as_string(path);
    let stamp = clock();
    let tmp_path = sprintf("%s.%d.%d.tmp", path, stamp[0], stamp[1]);
    let result = fs.writefile(tmp_path, sprintf("%J\n", value));
    if (result == null || (type(result) == "boolean" && !result)) {
        try { fs.unlink(tmp_path); } catch(e) {}
        return false;
    }
    if (!fs.rename(tmp_path, path)) {
        try { fs.unlink(tmp_path); } catch(e) {}
        return false;
    }
    return true;
}

function strip_internal_fields(value) {
    if (type(value) == "array") {
        for (let i = 0; i < length(value); i++)
            value[i] = strip_internal_fields(value[i]);
        return value;
    }

    if (type(value) == "object") {
        for (let key in keys(value)) {
            if (substr(key, 0, 2) == "__") {
                delete value[key];
                continue;
            }
            value[key] = strip_internal_fields(value[key]);
        }
    }

    return value;
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function object_key_count(value) {
    return type(value) == "object" ? length(keys(value)) : 0;
}

function option(section, key, fallback) {
    if (fallback == null)
        fallback = "";
    let value = object_or_empty(section)[key];
    if (value == null)
        return fallback;
    if (type(value) == "array")
        return join(" ", value);
    return as_string(value);
}

function list_option(section, key) {
    let value = object_or_empty(section)[key];
    if (value == null)
        return [];
    if (type(value) == "array")
        return value;
    let text = trim(as_string(value));
    return text == "" ? [] : split(text, /[ \t\r\n]+/);
}

function bool_option(section, key, fallback) {
    if (fallback == null)
        fallback = false;
    let value = option(section, key, fallback ? "1" : "0");
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function int_option(section, key, fallback) {
    let value = option(section, key, fallback);
    if (match(value, /[^0-9]/))
        return int(fallback, 10);
    return int(value, 10);
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

// Shell prologue that closes every descriptor a background spawn would inherit.
// ucode holds an open descriptor per require()d module for the lifetime of the
// interpreter and offers no way to close them or mark them close-on-exec, so
// every spawn inherits the whole set. On the router the watchdog carries ~90 of
// them and passes them to each child: `logread`, `sh`, and nfqws2 were all found
// holding descriptors on Tachyon's own .uc files, several already unlinked by a
// package upgrade — the old inode pinned on disk by a process with no interest
// in it.
//
// The codebase used to write a literal `1000<&-` against this, which closed
// nothing: no descriptor 1000 is ever opened, and every real one falls in 6..89.
//
// Two things make the replacement less obvious than it looks.
//
// Counting from 3 to a ceiling does not work. Closing a descriptor at or above
// 10 is fatal in dash even when the number was never open — dash relocates its
// own bookkeeping descriptors into that range, so the redirection is a hard
// error that kills the shell. `2>/dev/null` hides the message, not the death,
// and `|| true` never runs. Enumerating /proc/self/fd instead touches only
// descriptors that are actually open, and is cheaper besides.
//
// That still leaves the high descriptors themselves: a module set of any size
// puts them past 10, and under dash closing one kills the spawn outright. So the
// prologue asks first, in a subshell that absorbs the death, and lowers its own
// ceiling when the answer is no. busybox ash — what OpenWrt runs, and the shell
// this has to satisfy — answers yes and closes the whole set; dash closes 3..9
// and leaves the rest rather than taking the spawn down with it.
//
// The glob's own descriptor may appear in the listing and close underneath the
// loop; `|| true` keeps that from ending it. /proc is always mounted on OpenWrt.
//
// stdin/stdout/stderr are left alone — callers redirect those themselves.
function close_inherited_fds() {
    return "if ( eval \"exec 10<&-\" ) 2>/dev/null; then __tfd=999; else __tfd=9; fi; " +
        "for f in /proc/self/fd/*; do i=${f##*/}; case $i in 0|1|2) continue;; esac; " +
        "[ \"$i\" -le $__tfd ] 2>/dev/null || continue; " +
        "eval \"exec $i<&-\" 2>/dev/null || true; done; ";
}

// Wraps a command so it runs in the background with no inherited descriptors.
// This is the one place that knows how a Tachyon background spawn is shaped;
// callers used to hand-roll the redirections and drifted apart in the process.
function background_command(command) {
    return "{ " + close_inherited_fds() + as_string(command) + "; } </dev/null >/dev/null 2>&1 &";
}

// Splits any leading `VAR=value` assignments off the front of a command. `exec`
// has to go between them and the program name: `VAR=x exec prog` applies the
// assignment to prog, while `exec VAR=x prog` asks the shell to execute a
// program literally named `VAR=x` and fails. Several callers build their command
// as command_env({...}) + " " + command_from_args([...]), so the assignments are
// there in practice, not hypothetically.
//
// A token counts as an assignment only if it looks like one before any quoting:
// a name, then `=`. command_env() shell-quotes the value but never the name or
// the `=`, so this recognises what it produces without being fooled by an
// argument that merely contains one.
function split_leading_assignments(command) {
    let rest = trim(as_string(command));
    let assignments = "";

    while (true) {
        let matched = match(rest, /^([A-Za-z_][A-Za-z0-9_]*=[^ \t]*)[ \t]+/);
        if (!matched)
            break;
        assignments += matched[1] + " ";
        rest = substr(rest, length(matched[0]));
    }

    return { assignments, command: rest };
}

// Same, for spawns whose pid the caller needs. `$!` must report the daemon
// itself, so the descriptor loop runs inside the backgrounded subshell and
// `exec` replaces it with the command — leaving one process, whose pid is the
// subshell's. Wrapping the loop around the spawn instead would make `$!` name a
// short-lived shell that exits immediately, and the recorded pid would belong to
// nothing.
//
// `pid_sink` is the shell fragment that consumes the pid: "" leaves it on
// stdout for a capturing caller, ">'/path'" writes it to a pid file. It is
// emitted outside the subshell, so it is not affected by the redirections.
//
// `command` must be a single command, since `exec` replaces the shell with it.
// For pipelines and loops use background_pipeline_with_pid(), where `$!` names
// the last stage rather than the whole construct.
function background_command_with_pid(command, stdout_redirect, pid_sink) {
    let redirect = as_string(stdout_redirect || ">/dev/null");
    let sink = as_string(pid_sink);
    let split = split_leading_assignments(command);
    return "{ " + close_inherited_fds() + split.assignments + "exec " + split.command +
        "; } </dev/null " + redirect + " 2>&1 & echo $!" + (sink != "" ? " " + sink : "");
}

// For background constructs `exec` cannot replace the shell with — pipelines,
// loops, anything with more than one command. The descriptors are closed in the
// subshell as before, but without `exec` the subshell survives, so `$!` names
// that subshell rather than any single process inside it. Killing it does not
// necessarily kill its children, which is why the exec form above is preferred
// wherever the command is a single program.
function background_pipeline_with_pid(command, pid_sink) {
    let sink = as_string(pid_sink);
    return "{ " + close_inherited_fds() + as_string(command) +
        "; } </dev/null >/dev/null 2>&1 & echo $!" + (sink != "" ? " " + sink : "");
}

function command_status(command) {
    let status = int(system(command));
    if (status == -1)
        return 255;
    let signal = status & 127;
    if (signal != 0)
        return 128 + signal;
    return (status >> 8) & 255;
}

function command_success(command) {
    return command_status("(" + command + ") >/dev/null 2>&1") == 0;
}

function command_success_from_args(args) {
    return command_success(command_from_args(args));
}

function command_capture(command) {
    let p = fs.popen(command, "r");
    if (!p) return null;
    let output = as_string(p.read("all") || "");
    let status = p.close();
    if (status == -1)
        status = 255;
    else {
        let signal = status & 127;
        if (signal != 0)
            status = 128 + signal;
        else
            status = (status >> 8) & 255;
    }
    return { status: status, output: output };
}

function command_output(command) {
    let res = command_capture(command);
    return res ? res.output : "";
}

function command_output_from_args(args) {
    return command_output(command_from_args(args) + " 2>/dev/null");
}

return {
    as_string,
    read_json_file,
    read_stdin,
    read_stdin_json,
    write_json,
    write_compact_string_array,
    csv_to_json_array,
    write_json_file,
    strip_internal_fields,
    array_or_empty,
    object_or_empty,
    object_key_count,
    option,
    list_option,
    bool_option,
    int_option,
    shell_quote,
    command_from_args,
    close_inherited_fds,
    background_command,
    background_command_with_pid,
    background_pipeline_with_pid,
    command_status,
    command_success,
    command_success_from_args,
    command_capture,
    command_output,
    command_output_from_args
};