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

// ─── Flash wear guard ─────────────────────────────────────────────────────────
//
// On a router the flash is the scarcest resource that actually dies. NAND wears
// out long before the CPU does, and nearly everything Tachyon regenerates is
// derived data that comes back byte-identical most of the time: the per-channel
// domain lists, the compiled .srs/.trs rulesets,
// the subscription cache, the tachyon-core config.
//
// Measured on 192.168.1.1: one list update rewrote all 33 .srs rulesets - 2.5 MB
// - inside four minutes, with identical content, because the copy was
// unconditional. Nothing about that shows in the UI, and the router just gets a
// little more worn out every time.
//
// Writing identical bytes changes nothing except the wear counter, so compare
// first and skip. Size is checked before content, so the common "it really
// changed" case does not pay for a read, and the full compare only runs when the
// sizes match - which is precisely the case worth catching.
//
// The guard lives in the three central writers rather than at ~230 call sites
// because every regenerator funnels through one of them.
function content_unchanged(path, data) {
    let st = fs.stat(as_string(path));
    if (st == null || int(st.size) != length(as_string(data)))
        return false;
    return as_string(fs.readfile(path) || "") == as_string(data);
}

// The two unlinks below clean up the temporary file after a failed write or
// rename. Both failure paths already report to the caller through `false`, and
// an unlink that throws means the temp file was never created — nothing left
// to clean up.
function write_json_file(path, value, indent) {
    path = as_string(path);
    let fmt = (indent != null && indent > 0) ? sprintf("%%.%dJ\n", indent) : "%J\n";
    let content = sprintf(fmt, value);
    // Skip before the tmp file: the tmp write plus the rename is two flash
    // updates for a spec that came back identical, and the whole point of the
    // atomic write is corruption safety, which an unchanged file cannot lose.
    if (content_unchanged(path, content))
        return true;
    let stamp = clock();
    let tmp_path = sprintf("%s.%d.%d.tmp", path, stamp[0], stamp[1]);
    let result = fs.writefile(tmp_path, content);
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
    value = lc(trim(as_string(value)));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

// disable_quic has grown from a flag into three modes: "off" (no rule at all),
// "tunneled" (reject QUIC that never reaches tachyon-core, tachyon-core still decides
// what it is handed) and "all" (reject every UDP/443 outright). One
// normalizer for every reader — bool_value() would call both new modes false.
function disable_quic_mode(value) {
    value = lc(trim(as_string(value)));
    if (value == "all")
        return "all";
    if (value == "tunneled" || value == "1" || value == "true" || value == "yes" || value == "on")
        return "tunneled";
    return "off";
}

function bool_option(section, key, fallback) {
    if (fallback == null)
        fallback = false;
    let raw = trim(option(section, key, ""));
    let value = raw == "" ? (fallback ? "1" : "0") : raw;
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

let _ipv6_supported_cached = null;

function ipv6_supported() {
    // Environment override bypasses cache so tests can control the value per-call.
    let override = getenv("TACHYON_ENABLE_IPV6");
    if (override != null && override != "")
        return override == "1" || override == "true";
    // Cache the /proc result for the lifetime of this process: the kernel IPv6
    // support state does not change at runtime, and reading two /proc paths on
    // every probe tick adds unnecessary I/O on storage-constrained routers.
    if (_ipv6_supported_cached != null)
        return _ipv6_supported_cached;
    if (!fs.stat("/proc/net/if_inet6")) {
        if (!fs.stat("/proc"))
            _ipv6_supported_cached = true;
        else
            _ipv6_supported_cached = false;
        return _ipv6_supported_cached;
    }
    let data = fs.readfile("/proc/sys/net/ipv6/conf/all/disable_ipv6");
    if (data != null && trim(data) == "1")
        _ipv6_supported_cached = false;
    else
        _ipv6_supported_cached = true;
    return _ipv6_supported_cached;
}

// Normalize a custom-signature-packet value (AmneziaWG i1-i5 / j1-j3) into
// the tag-chain format understood by the userspace WireGuard shipped with
// tachyon-core ("<b 0x..>", "<r N>", "<rd N>", "<rc N>",
// "<c>", "<t>"). Existing tag chains pass through verbatim; classic
// AmneziaWG plain-hex payloads are wrapped into a static-bytes tag, because
// the userspace parser silently ignores bare hex and the handshake then
// never completes against servers expecting those packets.
function awg_tag_chain(value) {
    value = trim(as_string(value));
    if (value == "" || value == "0")
        return "";

    // Heal previously truncated tag chains (e.g. from broken conf import)
    if (match(value, /^[0-9a-fA-F]+><[^<>]+>/))
        value = "<b 0x" + value;
    if (match(value, /<[^<>]+$/))
        value = value + ">";

    // A well-formed tag chain: keep it verbatim, including inner spacing
    // ("<b 0x..>" carries a space inside each tag).
    if (match(value, /^(<[^<>]+>)+$/))
        return value;

    // Classic AmneziaWG form: plain hex (with optional 0x prefix).
    let hex = lc(value);
    hex = replace(hex, /^0x/, "");
    if (match(hex, /^[0-9a-f]+$/)) {
        if (length(hex) % 2 != 0)
            hex += "0";
        return "<b 0x" + hex + ">";
    }

    // Unsupported shape: emit nothing rather than a value that would be
    // silently dropped at runtime; validation reports it.
    return "";
}

// Providers hand out the fingerprint in the OpenSSL shape - hex byte pairs joined
// by colons - and in subscription links the colons arrive percent-encoded, so
// parse_query() has already decoded them back to "28:6A:02:...". Accepting only
// the bare 64-digit form silently dropped the pin: the node then connects with a
// certificate that fails CA or name validation, and nothing anywhere says why.
function certificate_pin_base64(value) {
    value = lc(trim(as_string(value)));
    // A field can carry more than one fingerprint. Take the leading run of hex and
    // colons, which stops at any separator, instead of a split on a character class:
    // \s inside a ucode regex does not reliably cover a plain space, and a field
    // that quietly failed to parse is exactly the bug this fixes.
    let leading = match(value, /^[0-9a-f:]+/);
    if (leading == null)
        return "";
    value = replace(as_string(leading[0]), /:/g, "");
    if (match(value, /^[0-9a-f]{64}$/) == null)
        return "";
    return b64enc(hexdec(value));
}

function bytes_to_hex(value) {
    value = as_string(value);
    let result = "";
    for (let i = 0; i < length(value); i++)
        result += sprintf("%02x", ord(value, i));
    return result;
}

// Normalize a stored MTProto secret into the canonical serialized hex form
// ("ee" + 16-byte key + faketls host) accepted by tachyon-core.
// Users paste the key or full secret in hex or base64; the parser
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
// Canonical implementation is in core/exec.uc. This wrapper exists for backward
// compatibility with the ~100+ call sites that import core.common.
function close_inherited_fds() {
    let exec_mod;
    try { exec_mod = require("core.exec"); } catch(e) {}
    if (exec_mod && exec_mod.close_inherited_fds)
        return exec_mod.close_inherited_fds();
    // Fallback if core.exec is not yet loaded
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

function normalize_status(status) {
    status = int(status);
    if (status < 0)
        return status == -1 ? 255 : 128 + (-status);
    if (status <= 255)
        return status;
    let signal = status & 127;
    if (signal != 0)
        return 128 + signal;
    return (status >> 8) & 255;
}

function command_status(command) {
    return normalize_status(system(command));
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

// The core binary runs as `tachyon-core`.
function core_binary_running() {
    return command_success_from_args([ "pidof", "tachyon-core" ]);
}

function command_capture(command) {
    let p = fs.popen(command, "r");
    if (!p) return null;
    let output = as_string(p.read("all") || "");
    let status = normalize_status(p.close());
    return { status: status, output: output };
}

function command_output(command) {
    let res = command_capture(command);
    return res ? res.output : "";
}

function command_output_from_args(args) {
    return command_output(command_from_args(args) + " 2>/dev/null");
}

let timeout_prefix_cache = null;

function timeout_prefix() {
    if (timeout_prefix_cache != null)
        return timeout_prefix_cache;

    if (command_status("timeout -k 1 1 /bin/true >/dev/null 2>&1") == 0)
        timeout_prefix_cache = [ "timeout", "-k", "5" ];
    else if (command_status("timeout 1 /bin/true >/dev/null 2>&1") == 0)
        timeout_prefix_cache = [ "timeout" ];
    else if (command_status("timeout -t 1 /bin/true >/dev/null 2>&1") == 0)
        timeout_prefix_cache = [ "timeout", "-t" ];
    else
        timeout_prefix_cache = [];

    return timeout_prefix_cache;
}

function bounded_command(command, seconds) {
    seconds = as_string(seconds || "30");
    let prefix = timeout_prefix();
    if (length(prefix) == 0)
        return "sh -c " + shell_quote("(" + as_string(command) + ") & __p=$!; ( sleep " + seconds + "; kill -9 $__p 2>/dev/null || true ) & __w=$!; wait $__p 2>/dev/null; __rc=$?; kill -9 $__w 2>/dev/null || true; wait $__w 2>/dev/null || true; exit $__rc");

    return join(" ", prefix) + " " + seconds + " sh -c " + shell_quote(as_string(command));
}

function kill_matching_command(grep_args) {
    return "__anc=\" \"; __p=$$; " +
        "while [ -n \"$__p\" ] && [ \"$__p\" -gt 1 ] 2>/dev/null; do " +
        "__anc=\"$__anc$__p \"; " +
        "__p=$(awk '{ sub(/.*\\) /, \"\"); print $2 }' \"/proc/$__p/stat\" 2>/dev/null); " +
        "done; " +
        "ps 2>/dev/null | grep " + grep_args + " | grep -v grep | grep -v -E 'action[.]uc|updates[.]uc|package[.]uc|migration[.]uc|package_postinst|package_prerm|luci_postinst' | awk '{print $1}' | " +
        "while read _pid; do case \"$__anc\" in *\" $_pid \"*) continue;; esac; " +
        "kill -9 \"$_pid\" 2>/dev/null; done; true";
}

// Kill orphaned logread -f processes. BusyBox OpenWrt lacks pkill, so we use
// pgrep (which IS available) piped to kill. The $ anchor avoids matching
// one-shot "logread -l N" calls from check_logs / diagnostics.
function kill_orphaned_logread() {
    return "pgrep -f 'logread -f$' 2>/dev/null | xargs kill 2>/dev/null; true";
}

function ensure_dir(path) {
    path = as_string(path);
    if (path == "") return false;
    let st = fs.stat(path);
    if (st != null && st.type == "directory") return true;
    let result = system("mkdir -p " + shell_quote(path) + " 2>/dev/null");
    return result == 0;
}

function remove_file(path) {
    path = as_string(path);
    if (path == "") return true;
    try { fs.unlink(path); return true; } catch (e) { return true; }
}

function copy_file(source, target) {
    source = as_string(source);
    target = as_string(target);
    let data = fs.readfile(source);
    if (data == null)
        return false;
    if (content_unchanged(target, data))
        return true;
    let slash = rindex(target, "/");
    if (slash > 0)
        ensure_dir(substr(target, 0, slash));
    let stamp = clock();
    let tmp = sprintf("%s.tmp.%d.%d", target, stamp[0], stamp[1]);
    if (fs.writefile(tmp, data) != null && fs.rename(tmp, target))
        return true;
    remove_file(tmp);
    return fs.writefile(target, data) != null;
}

// The copy that never holds the payload in the ucode heap. copy_file() reads
// the whole file with fs.readfile to compare and rewrite it, which is fine for
// a ruleset and fatal for a core binary: on the 256 MB router from issue
// #124 the installer was OOM-killed at 70-77 MB RSS backing up the old core.
// cp streams through the kernel instead. There is deliberately no
// unchanged-content guard here: comparing would need the very read this
// function exists to avoid, and the callers are binary backups into /tmp, not
// regenerated flash artifacts. Flash targets must keep using copy_file().
function copy_file_stream(source, target) {
    source = as_string(source);
    target = as_string(target);
    if (source == "" || target == "")
        return false;
    if (fs.stat(source) == null)
        return false;
    let slash = rindex(target, "/");
    if (slash > 0)
        ensure_dir(substr(target, 0, slash));
    let stamp = clock();
    let tmp = sprintf("%s.tmp.%d.%d", target, stamp[0], stamp[1]);
    if (command_success_from_args([ "cp", "-p", source, tmp ]) && fs.rename(tmp, target))
        return true;
    remove_file(tmp);
    return command_success_from_args([ "cp", "-p", source, target ]);
}

function unlink_file(path) {
    return remove_file(path);
}

function write_file(path, value) {
    path = as_string(path);
    value = as_string(value);
    if (content_unchanged(path, value))
        return length(value);
    return fs.writefile(path, value);
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

// The counterpart, kept beside parent_dir() so path handling that depends on
// where the slash is has exactly one implementation. Splitting instead of
// rindex() is deliberate: rindex() on a bare "/" returns 0, which is both a
// valid index and a falsy result, and reading it that way goes wrong quietly.
function path_basename(path) {
    let parts = split(as_string(path), "/");
    return length(parts) > 0 ? as_string(parts[length(parts) - 1]) : "";
}

// Recursive delete, used when something is abandoned rather than refreshed.
// Returns true when the path is gone afterwards. Deleting a directory that is
// already absent is success, not an error: every caller here is a cleanup, and
// a cleanup that fails because there was nothing to clean up is just noise.
function remove_tree(path) {
    path = as_string(path);
    let st = fs.stat(path);
    if (st == null)
        return true;
    if (type(st) == "object" && st.type == "directory") {
        let names = fs.lsdir(path);
        for (let name in array_or_empty(names))
            remove_tree(path + "/" + as_string(name));
        try { fs.rmdir(path); } catch (e) { return false; }
        return fs.stat(path) == null;
    }
    try { fs.unlink(path); } catch (e) { return false; }
    return fs.stat(path) == null;
}

// Override point for tests, same idea as TACHYON_LIB/TACHYON_CONFIG elsewhere:
// the suite runs unprivileged and cannot write /etc.
function core_config_path() {
    return getenv("TACHYON_CORE_CONFIG") || "/etc/tachyon-core/config.json";
}

function get_mixed_inbound_info() {
    let data = fs.readfile(core_config_path());
    if (data == null) return null;
    let parsed;
    try { parsed = json(data); } catch (e) { return null; }
    if (parsed == null || parsed.inbounds == null) return null;

    // 1. Explicitly check for the internal service mixed inbound
    for (let inbound in parsed.inbounds) {
        if (inbound.tag == "service-mixed-in" && inbound.listen_port != null) {
            let port = int(inbound.listen_port, 10);
            if (port > 0) {
                let host = as_string(inbound.listen || "127.0.0.1");
                if (host == "0.0.0.0" || host == "::" || host == "") host = "127.0.0.1";
                return { host: host, port: port, tag: inbound.tag };
            }
        }
    }
    // 2. Check for any mixed/http inbound listening on 127.0.0.1, 0.0.0.0, or ::
    for (let inbound in parsed.inbounds) {
        if ((inbound.type == "mixed" || inbound.type == "http") && inbound.listen_port != null) {
            let listen = as_string(inbound.listen || "");
            if (listen == "127.0.0.1" || listen == "0.0.0.0" || listen == "::" || listen == "") {
                let port = int(inbound.listen_port, 10);
                if (port > 0) return { host: "127.0.0.1", port: port, tag: inbound.tag };
            }
        }
    }
    // 3. Fallback to any mixed/http inbound port
    for (let inbound in parsed.inbounds) {
        if ((inbound.type == "mixed" || inbound.type == "http") && inbound.listen_port != null) {
            let port = int(inbound.listen_port, 10);
            if (port > 0) {
                let host = as_string(inbound.listen || "127.0.0.1");
                if (host == "0.0.0.0" || host == "::" || host == "") host = "127.0.0.1";
                return { host: host, port: port, tag: inbound.tag };
            }
        }
    }
    return null;
}

// Prefers the dedicated internal service mixed inbound (tag: service-mixed-in)
// or inbounds listening on 127.0.0.1/0.0.0.0.
// Falls back to 4534 when the config is missing or unparseable.
function get_mixed_port() {
    let info = get_mixed_inbound_info();
    return info ? info.port : 4534;
}

function get_lan_ip() {
    let out = trim(as_string(command_output("uci -q get network.lan.ipaddr 2>/dev/null") || ""));
    if (out != "")
        return out;
    return "192.168.1.1";
}

function get_mixed_proxy_endpoint() {
    let info = get_mixed_inbound_info();
    if (info && info.host && info.port) {
        let host = info.host;
        if (host == "0.0.0.0" || host == "::" || host == "")
            host = "127.0.0.1";
        return host + ":" + info.port;
    }
    return get_lan_ip() + ":" + get_mixed_port();
}


function hex_digit_value(value) {
    let pos = index("0123456789abcdef", lc(as_string(value)));
    return pos >= 0 ? pos : null;
}

function parse_number(value) {
    value = lc(trim(as_string(value)));
    if (value == "")
        return null;

    if (substr(value, 0, 2) == "0x") {
        value = substr(value, 2);
        if (value == "")
            return null;

        let result = 0;
        for (let i = 0; i < length(value); i++) {
            let digit = hex_digit_value(substr(value, i, 1));
            if (digit == null)
                return null;
            result = result * 16 + digit;
        }
        return result;
    }

    return match(value, /^[0-9]+$/) == null ? null : int(value, 10);
}

function file_first_line(path) {
    let data = fs.readfile(as_string(path));
    if (data == null)
        return "";
    let newline = index(data, "\n");
    return trim(newline >= 0 ? substr(data, 0, newline) : data);
}

// Reads the version out of `tachyon-core version` output.
//
// Matches the token that follows `tachyon-core` / `version` wherever it
// appears, and falls back to the first version-shaped token of the banner when
// the keyword is absent - never to the last token, which on a banner that puts
// the platform after the version is the platform.
// The character class is an explicit list rather than a negated one: \s includes
// \n in this regex engine, so "[^\s...]" runs past the end of the line and
// swallows the rest of the banner.
function parse_core_version(output) {
    let text = as_string(output);
    let m = match(text, /tachyon-core[ \t]+version[ \t]+(v?[0-9][0-9A-Za-z._+-]*)/);
    if (m != null)
        return as_string(m[1]);
    m = match(text, /tachyon-core[ \t]+(v?[0-9][0-9A-Za-z._+-]*)/);
    if (m != null)
        return as_string(m[1]);
    // No keyword anywhere. Take the first token of the banner that is actually
    // version-shaped rather than blindly the last one, so platform tokens are
    // never returned as versions.
    let newline = index(text, "\n");
    let line = trim(newline >= 0 ? substr(text, 0, newline) : text);
    for (let token in split(line, /[ \t\r\n]+/)) {
        let t = as_string(token);
        if (t != "" && match(t, /^v?[0-9][0-9A-Za-z._+-]*$/) != null)
            return t;
    }
    return "";
}

function print_file_first_line(path) {
    let data = fs.readfile(as_string(path));
    if (data == null)
        exit(1);
    let newline = index(data, "\n");
    print(newline >= 0 ? substr(data, 0, newline) : data, "\n");
}

function section_name(section) {
    return as_string(object_or_empty(section)[".name"]);
}

function contains(arr, val) {
    if (type(arr) != "array")
        return false;
    return index(arr, val) >= 0;
}

function normalize_ipv6_mode(value) {
    let raw = lc(trim(as_string(value)));
    if (raw == "" || raw == "auto" || raw == "1" || raw == "true")
        return "auto";
    if (raw == "off" || raw == "ipv4_only" || raw == "ipv4-only" || raw == "ipv4" || raw == "0" || raw == "false" || raw == "disabled" || raw == "none")
        return "off";
    if (raw == "dual_stack" || raw == "dual-stack" || raw == "ipv4_ipv6" || raw == "ipv4-ipv6" || raw == "on" || raw == "full" || raw == "always")
        return "dual_stack";
    if (raw == "tunnel_over_v4" || raw == "tunnel-over-v4" || raw == "v6_over_v4" || raw == "v6-over-v4" || raw == "tunnel")
        return "tunnel_over_v4";
    return "auto";
}

function is_fakeip_enabled(settings) {
    settings = object_or_empty(settings);
    if (trim(option(settings, "fakeip_enabled", "")) != "")
        return bool_option(settings, "fakeip_enabled", true);
    if (trim(option(settings, "fakeip", "")) != "")
        return bool_option(settings, "fakeip", true);
    return true;
}

function is_tcp_bbr_enabled(settings) {
    settings = object_or_empty(settings);
    if (trim(option(settings, "tcp_bbr", "")) != "")
        return bool_option(settings, "tcp_bbr", true);
    return true;
}

function ipv6_state_cache_path() {
    return getenv("TACHYON_IPV6_STATE_CACHE") || "/var/run/tachyon/ipv6-state.json";
}

function is_tmpfs_runtime_path(path) {
    path = as_string(path);
    return substr(path, 0, 9) == "/var/run/" || substr(path, 0, 5) == "/run/" || substr(path, 0, 5) == "/tmp/";
}

function is_local_or_ula_v6(addr) {
    addr = lc(trim(as_string(addr)));
    let slash = index(addr, "/");
    if (slash >= 0)
        addr = substr(addr, 0, slash);
    if (addr == "" || addr == "::" || addr == "::1")
        return true;
    if (match(addr, /^fe[89ab][0-9a-f]?:/))
        return true;
    if (match(addr, /^f[cd][0-9a-f]{0,2}:/))
        return true;
    return false;
}

function is_non_wan_iface_name(name) {
    name = lc(trim(as_string(name)));
    if (name == "" || name == "lo" || name == "loopback" || name == "lan" || name == "br-lan")
        return true;
    if (substr(name, 0, 3) == "lan" || substr(name, 0, 3) == "tun" || substr(name, 0, 3) == "tap")
        return true;
    if (substr(name, 0, 9) == "tailscale" || substr(name, 0, 6) == "wg_tap")
        return true;
    return false;
}

function parse_mock_cidr_list(raw) {
    let out = [];
    let seen = {};
    let items = type(raw) == "array" ? raw : split(trim(as_string(raw)), /[ \t\r\n,;]+/);
    for (let item in items) {
        item = trim(as_string(item));
        if (item != "" && index(item, ":") >= 0 && !seen[item]) {
            seen[item] = true;
            push(out, item);
        }
    }
    return out;
}

function wan6_live_status() {
    let kernel_v6 = ipv6_supported();
    let mock_pd = parse_mock_cidr_list(getenv("TACHYON_MOCK_WAN6_PD") || "");
    let mock_raw = trim(as_string(getenv("TACHYON_MOCK_WAN6_STATUS") || ""));

    if (mock_raw != "") {
        let lower = lc(mock_raw);
        if (substr(mock_raw, 0, 1) == "{") {
            let parsed = null;
            try { parsed = json(mock_raw); } catch (e) { parsed = null; }
            if (type(parsed) == "object") {
                let pd = parse_mock_cidr_list(parsed.wan6_pd != null ? parsed.wan6_pd : (parsed.pd || mock_pd));
                let gua = parse_mock_cidr_list(parsed.wan6_gua != null ? parsed.wan6_gua : (parsed.gua || []));
                let avail = kernel_v6 && !!(parsed.available || length(pd) > 0 || length(gua) > 0 || parsed.default_route6);
                return {
                    available: avail,
                    kernel_v6: kernel_v6,
                    wan6_iface: as_string(parsed.wan6_iface || (avail ? "wan6" : "")),
                    wan6_pd: pd,
                    wan6_gua: gua,
                    default_route6: !!(parsed.default_route6 != null ? parsed.default_route6 : avail),
                    source: "mock"
                };
            }
        }
        let mock_up = (lower == "1" || lower == "true" || lower == "yes" || lower == "up");
        let avail = kernel_v6 && mock_up;
        return {
            available: avail,
            kernel_v6: kernel_v6,
            wan6_iface: avail ? "wan6" : "",
            wan6_pd: avail ? mock_pd : [],
            wan6_gua: [],
            default_route6: avail,
            source: "mock"
        };
    }

    if (length(mock_pd) > 0) {
        return {
            available: kernel_v6,
            kernel_v6: kernel_v6,
            wan6_iface: kernel_v6 ? "wan6" : "",
            wan6_pd: kernel_v6 ? mock_pd : [],
            wan6_gua: [],
            default_route6: kernel_v6,
            source: "mock"
        };
    }

    if (!kernel_v6) {
        return {
            available: false,
            kernel_v6: false,
            wan6_iface: "",
            wan6_pd: [],
            wan6_gua: [],
            default_route6: false,
            source: "kernel"
        };
    }

    if (getenv("TACHYON_NO_LIVE_NET_PROBE") == "1") {
        return {
            available: false,
            kernel_v6: true,
            wan6_iface: "",
            wan6_pd: [],
            wan6_gua: [],
            default_route6: false,
            source: "probe_disabled"
        };
    }

    let wan6_iface = "";
    let wan6_pd = [];
    let wan6_gua = [];
    let seen_pd = {};
    let seen_gua = {};
    let default_route6 = false;
    let default_dev = "";

    let route_out = command_output_from_args([ "ip", "-6", "-o", "route", "show", "default" ]);
    for (let line in split(as_string(route_out), "\n")) {
        line = trim(line);
        if (line == "")
            continue;
        let m = match(line, /(^|[ \t])dev[ \t]+([^ \t]+)/);
        let dev = m ? as_string(m[2]) : "";
        if (is_non_wan_iface_name(dev))
            continue;
        default_route6 = true;
        if (default_dev == "" && dev != "")
            default_dev = dev;
    }

    let ubus_raw = command_output(bounded_command(command_from_args([ "ubus", "call", "network.interface", "dump" ]), 3) + " 2>/dev/null");
    if (trim(ubus_raw) != "") {
        let parsed = null;
        try { parsed = json(ubus_raw); } catch (e) { parsed = null; }
        let ifaces = type(parsed) == "object" ? array_or_empty(parsed["interface"]) : [];
        for (let iface in ifaces) {
            if (type(iface) != "object" || !iface.up)
                continue;
            let iname = as_string(iface.interface || "");
            let l3dev = as_string(iface.l3_device || iface.device || "");
            if (is_non_wan_iface_name(iname) || is_non_wan_iface_name(l3dev))
                continue;

            let had_v6 = false;
            for (let p in array_or_empty(iface["ipv6-prefix"])) {
                if (type(p) != "object" || as_string(p.address || "") == "")
                    continue;
                let cidr = as_string(p.address) + "/" + as_string(p.mask != null ? p.mask : 64);
                if (!seen_pd[cidr]) {
                    seen_pd[cidr] = true;
                    push(wan6_pd, cidr);
                }
                had_v6 = true;
            }
            for (let a in array_or_empty(iface["ipv6-address"])) {
                if (type(a) != "object" || as_string(a.address || "") == "")
                    continue;
                if (is_local_or_ula_v6(a.address))
                    continue;
                let cidr = as_string(a.address) + "/" + as_string(a.mask != null ? a.mask : 128);
                if (!seen_gua[cidr]) {
                    seen_gua[cidr] = true;
                    push(wan6_gua, cidr);
                }
                had_v6 = true;
            }
            if (had_v6 && (wan6_iface == "" || iname == "wan6" || l3dev == default_dev))
                wan6_iface = iname != "" ? iname : l3dev;
        }
    }

    if (length(wan6_pd) == 0 && length(wan6_gua) == 0) {
        let addr_out = command_output_from_args([ "ip", "-6", "-o", "addr", "show", "scope", "global" ]);
        for (let line in split(as_string(addr_out), "\n")) {
            line = trim(line);
            if (line == "")
                continue;
            let m = match(line, /^[0-9]+:[ \t]+([^ \t]+)[ \t]+inet6[ \t]+([^ \t]+)/);
            if (!m)
                continue;
            let dev = as_string(m[1]);
            let cidr = as_string(m[2]);
            if (is_non_wan_iface_name(dev) || is_local_or_ula_v6(cidr))
                continue;
            if (!seen_gua[cidr]) {
                seen_gua[cidr] = true;
                push(wan6_gua, cidr);
            }
            if (wan6_iface == "" || dev == default_dev)
                wan6_iface = dev;
        }
    }

    if (wan6_iface == "" && default_dev != "")
        wan6_iface = default_dev;

    return {
        available: default_route6 || length(wan6_pd) > 0 || length(wan6_gua) > 0,
        kernel_v6: true,
        wan6_iface: wan6_iface,
        wan6_pd: wan6_pd,
        wan6_gua: wan6_gua,
        default_route6: default_route6,
        source: "live"
    };
}

function cache_ipv6_runtime_state(state_obj) {
    let path = ipv6_state_cache_path();
    if (!is_tmpfs_runtime_path(path))
        return false;
    let dir = parent_dir(path);
    if (dir != "")
        ensure_dir(dir);
    return write_json_file(path, object_or_empty(state_obj), 2);
}

function read_cached_ipv6_state() {
    return read_json_file(ipv6_state_cache_path());
}

function resolve_effective_ipv6_state(settings, wan6_info) {
    settings = object_or_empty(settings);

    let raw_mode = trim(option(settings, "ipv6_mode", ""));
    let mode = "";
    if (raw_mode != "") {
        mode = normalize_ipv6_mode(raw_mode);
    } else if (trim(option(settings, "ipv6_enabled", "")) != "") {
        mode = bool_option(settings, "ipv6_enabled", false) ? "auto" : "off";
    } else if (trim(option(settings, "enable_ipv6", "")) != "") {
        mode = bool_option(settings, "enable_ipv6", false) ? "auto" : "off";
    } else {
        mode = "auto";
    }

    let leak_guard = bool_option(settings, "ipv6_leak_guard", true);
    let kernel_v6 = (type(wan6_info) == "object" && wan6_info.kernel_v6 != null) ? !!(wan6_info.kernel_v6) : ipv6_supported();

    if (wan6_info == null && mode == "auto" && kernel_v6)
        wan6_info = wan6_live_status();

    let wan6_available = type(wan6_info) == "object" ? !!(wan6_info.available) : false;
    let effective = "disabled";
    if (!kernel_v6) {
        effective = "disabled";
    } else if (mode == "off") {
        effective = leak_guard ? "leak_guard" : "disabled";
    } else if (mode == "tunnel_over_v4") {
        effective = "tunnel_over_v4";
    } else if (mode == "dual_stack") {
        effective = "full";
    } else {
        effective = wan6_available ? "full" : (leak_guard ? "leak_guard" : "disabled");
    }

    let ipv6_active = (effective == "full" || effective == "tunnel_over_v4");
    let configured_dns_strategy = lc(trim(option(settings, "dns_strategy", "prefer_ipv4")));
    if (!contains([ "prefer_ipv4", "ipv4_only", "prefer_ipv6", "ipv6_only" ], configured_dns_strategy))
        configured_dns_strategy = "prefer_ipv4";

    let runtime_dns_strategy = ipv6_active ? configured_dns_strategy : "ipv4_only";

    return {
        ipv6_mode: mode,
        ipv6_leak_guard: leak_guard,
        kernel_v6: kernel_v6,
        wan6_available: wan6_available,
        wan6_iface: type(wan6_info) == "object" ? as_string(wan6_info.wan6_iface || "") : "",
        wan6_pd: type(wan6_info) == "object" ? array_or_empty(wan6_info.wan6_pd) : [],
        wan6_gua: type(wan6_info) == "object" ? array_or_empty(wan6_info.wan6_gua) : [],
        default_route6: type(wan6_info) == "object" ? !!(wan6_info.default_route6) : false,
        effective: effective,
        ipv6_active: ipv6_active,
        leak_guard_active: effective == "leak_guard",
        configured_dns_strategy: configured_dns_strategy,
        runtime_dns_strategy: runtime_dns_strategy,
        fakeip_enabled: is_fakeip_enabled(settings)
    };
}

function effective_dns_strategy(settings, effective_state) {
    if (type(effective_state) == "object" && effective_state.runtime_dns_strategy != null)
        return effective_state.runtime_dns_strategy;
    return resolve_effective_ipv6_state(settings, null).runtime_dns_strategy;
}

function ipv6_signature_pairs(settings, include_fakeip_detail) {
    settings = object_or_empty(settings);
    let pairs = [];
    let eff = resolve_effective_ipv6_state(settings, null);
    if (eff.ipv6_mode != "auto")
        push(pairs, [ "settings.ipv6_mode", eff.ipv6_mode ]);
    if (!eff.ipv6_leak_guard)
        push(pairs, [ "settings.ipv6_leak_guard", "0" ]);
    if (!eff.fakeip_enabled)
        push(pairs, [ "settings.fakeip_enabled", "0" ]);
    if (eff.effective != "leak_guard" && !(eff.ipv6_mode == "off" && !eff.ipv6_leak_guard))
        push(pairs, [ "runtime.ipv6_effective_state", eff.effective ]);
    if (eff.ipv6_active && length(eff.wan6_pd) > 0)
        push(pairs, [ "runtime.wan6_pd", join(",", eff.wan6_pd) ]);
    let f4 = trim(option(settings, "fakeip_inet4_range", "198.18.0.0/15"));
    if (f4 != "" && f4 != "198.18.0.0/15")
        push(pairs, [ "settings.fakeip_inet4_range", f4 ]);
    let f6 = trim(option(settings, "fakeip_inet6_range", "fc00::/18"));
    if (f6 != "" && f6 != "fc00::/18")
        push(pairs, [ "settings.fakeip_inet6_range", f6 ]);
    if (include_fakeip_detail) {
        let ex = list_option(settings, "fakeip_exclude");
        if (length(ex) > 0)
            push(pairs, [ "settings.fakeip_exclude", join("\n", ex) ]);
    }
    return pairs;
}

function parse_fragment_non_negative_int(val) {
    if (type(val) == "int" || type(val) == "double") {
        let n = int(val);
        return (n == val && n >= 0) ? n : null;
    }
    if (type(val) == "string") {
        let s = trim(val);
        if (match(s, /^[0-9]+$/) != null)
            return int(s, 10);
    }
    return null;
}

function sanitize_fragment_u64_range(val, min_lo) {
    if (val == null)
        return null;

    if (type(val) == "int" || type(val) == "double") {
        let n = int(val);
        return (n == val && n >= min_lo) ? n : null;
    }

    if (type(val) == "object" || (type(val) == "array" && length(val) == 2)) {
        let lo = parse_fragment_non_negative_int(type(val) == "object" ? val.from : val[0]);
        let hi = parse_fragment_non_negative_int(type(val) == "object" ? val.to : val[1]);
        if (lo == null || hi == null)
            return null;
        if (lo > hi) {
            let tmp = lo;
            lo = hi;
            hi = tmp;
        }
        if (hi < min_lo)
            return null;
        if (lo < min_lo)
            lo = min_lo;
        return lo == hi ? as_string(lo) : (as_string(lo) + "-" + as_string(hi));
    }

    if (type(val) != "string")
        return null;

    let s = trim(val);
    if (s == "")
        return null;

    if (match(s, /^[0-9]+$/) != null) {
        let n = int(s, 10);
        return n >= min_lo ? as_string(n) : null;
    }

    let mr = match(s, /^([0-9]+)[ \t]*-[ \t]*([0-9]+)$/);
    if (mr != null) {
        let lo = int(mr[1], 10);
        let hi = int(mr[2], 10);
        if (lo > hi) {
            let tmp = lo;
            lo = hi;
            hi = tmp;
        }
        if (hi < min_lo)
            return null;
        if (lo < min_lo)
            lo = min_lo;
        return lo == hi ? as_string(lo) : (as_string(lo) + "-" + as_string(hi));
    }

    return null;
}

function parse_fragment_delay_token_ms(tok) {
    tok = trim(as_string(tok));
    if (tok == "")
        return null;

    let ms_m = match(tok, /^([0-9]+)(ms)?$/i);
    if (ms_m != null) {
        let canon = ms_m[2] != null ? (ms_m[1] + "ms") : ms_m[1];
        return { raw: canon, ms: int(ms_m[1], 10) };
    }

    let s_m = match(tok, /^([0-9]+)(?:\.([0-9]+))?s$/i);
    if (s_m != null) {
        let whole = int(s_m[1], 10);
        let frac = s_m[2] || "";
        let frac_ms = 0;
        if (frac != "") {
            let padded = substr(frac + "0000", 0, 4);
            frac_ms = int(substr(padded, 0, 3), 10) + (int(substr(padded, 3, 1), 10) >= 5 ? 1 : 0);
        }
        return {
            raw: substr(tok, 0, length(tok) - 1) + "s",
            ms: whole * 1000 + frac_ms
        };
    }

    return null;
}

function sanitize_fragment_delay_range(val) {
    if (val == null)
        return null;

    if (type(val) == "int" || type(val) == "double") {
        let n = int(val);
        return (n == val && n >= 0) ? n : null;
    }

    if (type(val) != "string")
        return null;

    let s = trim(val);
    if (s == "")
        return null;

    let dash = index(s, "-");
    if (dash < 0) {
        let single = parse_fragment_delay_token_ms(s);
        return single != null ? single.raw : null;
    }

    let tail = substr(s, dash + 1);
    if (index(tail, "-") >= 0)
        return null;

    let lo = parse_fragment_delay_token_ms(substr(s, 0, dash));
    let hi = parse_fragment_delay_token_ms(tail);
    if (lo == null || hi == null)
        return null;

    return lo.ms > hi.ms ? (hi.raw + "-" + lo.raw) : (lo.raw + "-" + hi.raw);
}

function sanitize_dialer_fragment_object(frag) {
    if (type(frag) != "object")
        return;

    if ("max_split" in frag || "maxSplit" in frag) {
        let raw_ms = frag.max_split != null ? frag.max_split : frag.maxSplit;
        delete frag.maxSplit;
        let norm_ms = sanitize_fragment_u64_range(raw_ms, 1);
        if (norm_ms != null)
            frag.max_split = norm_ms;
        else
            delete frag.max_split;
    }

    for (let k in [ "lengths", "length" ]) {
        if (k in frag) {
            let norm_l = sanitize_fragment_u64_range(frag[k], 1);
            if (norm_l != null)
                frag[k] = norm_l;
            else
                delete frag[k];
        }
    }

    for (let k in [ "delays", "delay", "interval" ]) {
        if (k in frag) {
            let norm_d = sanitize_fragment_delay_range(frag[k]);
            if (norm_d != null)
                frag[k] = norm_d;
            else
                delete frag[k];
        }
    }

    if ("packets" in frag) {
        let pv = frag.packets;
        if (pv == null) {
            delete frag.packets;
        } else if (type(pv) == "int" || type(pv) == "double") {
            let pn = int(pv);
            if (pn != pv || pn < 0) {
                delete frag.packets;
            } else if (pn == 0) {
                delete frag.packets;
                frag.enabled = false;
            }
        } else if (type(pv) == "string") {
            let ps = trim(pv);
            let plc = lc(ps);
            if (ps == "") {
                delete frag.packets;
            } else if (plc == "tlshello" || plc == "tls_hello") {
                frag.packets = "tlshello";
            } else if (ps == "0" || ps == "0-0") {
                delete frag.packets;
                frag.enabled = false;
            } else {
                let norm_p = sanitize_fragment_u64_range(ps, 1);
                if (norm_p != null)
                    frag.packets = norm_p;
                else
                    delete frag.packets;
            }
        } else {
            delete frag.packets;
        }
    }
}

function sanitize_outbound_dialer_fragments(outbound) {
    if (type(outbound) != "object")
        return outbound;

    let otype = lc(trim(as_string(outbound.type || "")));
    let is_openvpn = (otype == "openvpn" || otype == "openvpn-client");
    if (!is_openvpn && type(outbound.fragment) == "object")
        sanitize_dialer_fragment_object(outbound.fragment);
    if (type(outbound.tcp_fragment) == "object")
        sanitize_dialer_fragment_object(outbound.tcp_fragment);
    if (type(outbound.finalmask) == "object" && outbound.finalmask.tcp != null) {
        let tcp_val = outbound.finalmask.tcp;
        let items = type(tcp_val) == "array" ? tcp_val : (type(tcp_val) == "object" ? [ tcp_val ] : []);
        for (let item in items) {
            if (type(item) == "object") {
                let itype = lc(as_string(item.type || ""));
                if (itype == "fragment" || itype == "tcp_fragment")
                    sanitize_dialer_fragment_object(type(item.settings) == "object" ? item.settings : item);
            }
        }
    }
    return outbound;
}

function sanitize_config_dialer_fragments(config) {
    if (type(config) != "object")
        return config;
    if (type(config.outbounds) == "array") {
        for (let ob in config.outbounds)
            sanitize_outbound_dialer_fragments(ob);
    }
    if (type(config.endpoints) == "array") {
        for (let ep in config.endpoints)
            sanitize_outbound_dialer_fragments(ep);
    }
    return config;
}

function log_message(message, level, tag) {
    // Delegate to unified structured logging module.
    // Maintains backward-compatible signature: log_message(message, level, tag)
    try {
        let logging = require("core.logging");
        return logging.log_message(message, level, tag);
    } catch (e) {
        // Fallback if logging module cannot be loaded
        level = as_string(level || "info");
        tag = as_string(tag || "tachyon");
        command_success_from_args([ "logger", "-t", tag, "[" + level + "] " + as_string(message) ]);
    }
}

return {
    as_string,
    hex_digit_value,
    parse_number,
    file_first_line,
    parse_core_version,
    print_file_first_line,
    section_name,
    contains,
    log_message,
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
    disable_quic_mode,
    int_option,
    int_or_range_option,
    bytes_to_hex,
    certificate_pin_base64,
    awg_tag_chain,
    sanitize_fragment_u64_range,
    sanitize_fragment_delay_range,
    sanitize_dialer_fragment_object,
    sanitize_outbound_dialer_fragments,
    sanitize_config_dialer_fragments,
    mtproto_secret_canonical,
    shell_quote,
    command_from_args,
    close_inherited_fds,
    background_command,
    background_command_with_pid,
    background_pipeline_with_pid,
    normalize_status,
    command_status,
    command_success,
    command_status_from_args,
    command_success_from_args,
    core_binary_running,
    command_capture,
    command_output,
    command_output_from_args,
    ensure_dir,
    remove_file,
    copy_file,
    copy_file_stream,
    unlink_file,
    write_file,
    content_unchanged,
    file_exists,
    remove_tree,
    parent_dir,
    path_basename,
    core_config_path,
    get_mixed_inbound_info,
    get_mixed_port,
    get_lan_ip,
    get_mixed_proxy_endpoint,
    timeout_prefix,
    bounded_command,
    kill_matching_command,
    kill_orphaned_logread,
    ipv6_supported,
    normalize_ipv6_mode,
    is_fakeip_enabled,
    is_tcp_bbr_enabled,
    ipv6_state_cache_path,
    is_tmpfs_runtime_path,
    is_local_or_ula_v6,
    wan6_live_status,
    cache_ipv6_runtime_state,
    read_cached_ipv6_state,
    resolve_effective_ipv6_state,
    effective_dns_strategy,
    ipv6_signature_pairs
};