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

// The two unlinks below clean up the temporary file after a failed write or
// rename. Both failure paths already report to the caller through `false`, and
// an unlink that throws means the temp file was never created — nothing left
// to clean up.
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

function bool_value(value) {
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function bool_option(section, key, fallback) {
    if (fallback == null)
        fallback = false;
    let value = option(section, key, fallback ? "1" : "0");
    return bool_value(value);
}

function int_option(section, key, fallback) {
    let value = option(section, key, fallback);
    if (match(value, /[^0-9]/))
        return int(fallback, 10);
    return int(value, 10);
}

function int_or_range_option(section, key, fallback) {
    let value = trim(as_string(option(section, key, "")));
    if (match(value, /^[0-9]+$/))
        return int(value, 10);
    if (match(value, /^[0-9]+-[0-9]+$/))
        return value;
    return fallback;
}

// Normalize a custom-signature-packet value (AmneziaWG i1-i5 / j1-j3) into
// the tag-chain format understood by the userspace WireGuard shipped with
// sing-box-extended and sing-box-lx ("<b 0x..>", "<r N>", "<rd N>", "<rc N>",
// "<c>", "<t>"). Existing tag chains pass through verbatim; classic
// AmneziaWG plain-hex payloads are wrapped into a static-bytes tag, because
// the userspace parser silently ignores bare hex and the handshake then
// never completes against servers expecting those packets.
function awg_tag_chain(value) {
    value = trim(as_string(value));
    if (value == "" || value == "0")
        return "";

    // A well-formed tag chain: keep it verbatim, including inner spacing
    // ("<b 0x..>" carries a space inside each tag).
    if (match(value, /^(<[^<>]+>)+$/))
        return value;

    // Classic AmneziaWG form: plain hex (with optional 0x prefix).
    let hex = lc(value);
    hex = replace(hex, /^0x/, "");
    if (match(hex, /^[0-9a-f]+$/) && length(hex) % 2 == 0)
        return "<b 0x" + hex + ">";

    // Unsupported shape: emit nothing rather than a value that would be
    // silently dropped at runtime; validation reports it.
    return "";
}


// The j1/j2/j3/itime WireGuardAmnezia fields exist only up to
// sing-box-extended v1.13.16-extended-2.6.0; starting with 2.6.1 (Amnezia 3.0
// integration) they were removed from the schema and sing-box aborts on
// unknown JSON fields.
function extended_awg_schema_has_junk_signatures(version) {
    let m = match(lc(as_string(version)), /extended-([0-9]+)\.([0-9]+)\.([0-9]+)/);
    if (m == null)
        return false;

    let major = int(m[1], 10);
    let minor = int(m[2], 10);
    let patch = int(m[3], 10);

    if (major < 2) return true;
    if (major > 2) return false;
    if (minor < 6) return true;
    if (minor > 6) return false;
    return patch <= 0;
}


function bytes_to_hex(value) {
    value = as_string(value);
    let result = "";
    for (let i = 0; i < length(value); i++)
        result += sprintf("%02x", ord(value, i));
    return result;
}

// Normalize a stored MTProto secret into the canonical serialized hex form
// ("ee" + 16-byte key + faketls host) that sing-box-extended (mtg-multi)
// accepts. Users paste the key or full secret in hex or base64; mtg-multi
// tries hex first and then raw-url base64, so mirror that precedence.
// Returns null when the value cannot be interpreted as a valid secret.
function mtproto_secret_canonical(secret, faketls) {
    secret = trim(as_string(secret));
    faketls = trim(as_string(faketls == null ? "google.com" : faketls));
    if (secret == "" || faketls == "")
        return null;

    let lower = lc(secret);

    // Hex form: a fully serialized "ee..." secret or a bare 16-byte key.
    if (length(lower) % 2 == 0 && match(lower, /^[0-9a-f]+$/)) {
        if (substr(lower, 0, 2) == "ee")
            return lower;
        return "ee" + lower + bytes_to_hex(faketls);
    }

    // Base64 form: translate to the standard alphabet and pad.
    let b64 = replace(replace(secret, /-/g, "+"), /_/g, "/");
    let remainder = length(b64) % 4;
    if (remainder == 1)
        return null;
    while (length(b64) % 4 > 0)
        b64 += "=";

    let decoded = b64dec(b64);
    if (decoded == null || decoded == false)
        return null;

    // Serialized secret: 0xee marker + key(16) + host(>=1).
    if (ord(decoded, 0) == 238) {
        if (length(decoded) < 18)
            return null;
        return bytes_to_hex(decoded);
    }

    // Bare key bytes: wrap them into the serialized form ourselves.
    if (length(decoded) < 16)
        return null;
    return "ee" + substr(bytes_to_hex(decoded), 0, 32) + bytes_to_hex(faketls);
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
// The ceiling has to sit above 1000, not below it. procd_lock() in
// /lib/functions/procd.sh does `exec 1000>/var/lock/procd_<svc>.lock` and then
// `flock 1000` with no -w, so descriptor 1000 IS the procd serialization lock.
// A ceiling of 999 skipped exactly that descriptor: every background spawn
// inherited the held lock, and the lock outlived the init script that took it —
// watchdog workers, logread -f, the zapret2 supervisors, nfqws2, the telegram
// worker and stray curls were all found pinning /var/lock/procd_tachyon.lock.
// With the lock never released, any later /etc/init.d/tachyon call blocks
// forever in flock, which is how package_prerm hung until apk killed it and
// rolled the upgrade back. Killing the flock processes cannot help while an
// inheriting child still holds the descriptor.
//
// stdin/stdout/stderr are left alone — callers redirect those themselves.
function close_inherited_fds() {
    return "if ( eval \"exec 10<&-\" ) 2>/dev/null; then __tfd=1048576; else __tfd=9; fi; " +
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

function command_status_from_args(args) {
    return command_status(command_from_args(args));
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

function ensure_dir(path) {
    path = as_string(path);
    if (path == "") return false;
    let result = system("mkdir -p " + shell_quote(path) + " 2>/dev/null");
    return result == 0;
}

function remove_file(path) {
    path = as_string(path);
    if (path == "") return true;
    try { fs.unlink(path); return true; } catch (e) { return true; }
}

function unlink_file(path) {
    return remove_file(path);
}

function write_file(path, value) {
    return fs.writefile(as_string(path), as_string(value));
}

function file_exists(path) {
    let s = fs.stat(as_string(path));
    return s != null;
}

function parent_dir(path) {
    path = as_string(path);
    let slash = rindex(path, "/");
    return slash >= 0 ? substr(path, 0, slash) : "";
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
    bool_value,
    int_option,
    int_or_range_option,
    bytes_to_hex,
    extended_awg_schema_has_junk_signatures,
    awg_tag_chain,
    mtproto_secret_canonical,
    shell_quote,
    command_from_args,
    close_inherited_fds,
    background_command,
    background_command_with_pid,
    background_pipeline_with_pid,
    command_status,
    command_success,
    command_status_from_args,
    command_success_from_args,
    command_capture,
    command_output,
    command_output_from_args,
    ensure_dir,
    remove_file,
    unlink_file,
    write_file,
    file_exists,
    parent_dir
};