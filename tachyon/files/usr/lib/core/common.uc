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
// derived data that comes back byte-identical most of the time: the steer spec,
// the per-channel domain lists, the zapret opts files, the compiled .srs rulesets,
// the subscription cache, the sing-box config.
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
// sing-box-extended and sing-box-lx ("<b 0x..>", "<r N>", "<rd N>", "<rc N>",
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

// OpenVPN endpoint support was added in sing-box 1.14.0 (upstream, and
// sing-box-extended that tracks it). Versions below 1.14.0 abort with
// "unknown endpoint type: openvpn" when they encounter the endpoint.
function sing_box_supports_openvpn(version) {
    // Version string examples:
    //   "1.14.1-extended-2.7.2"  ->  core 1.14.1  -> supported
    //   "1.13.16-extended-2.6.0" ->  core 1.13.16 -> NOT supported
    //   "1.14.0"                 ->  core 1.14.0  -> supported
    let m = match(as_string(version), /^([0-9]+)\.([0-9]+)\./);
    if (m == null)
        return false; // unknown format - assume not supported
    let major = int(m[1], 10);
    let minor = int(m[2], 10);
    if (major > 1) return true;
    if (major < 1) return false;
    return minor >= 14;
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

let nfqws_blob_probe_cache = {};

// zapret2 1.0.5+ compiles fake_default_http/tls/quic into nfqws2 itself, so a
// --blob= for those is a fatal "duplicate blob name" and the daemon never
// starts. Ask the binary instead of guessing from a version string: --dry-run
// verifies parameters and exits before touching any queue. The complaint goes to
// stderr, hence 2>&1 rather than the usual 2>/dev/null.
function nfqws_blob_is_builtin(bin, name, probe_file) {
    if (!bin || !name || !probe_file) return false;
    let key = as_string(bin) + "\t" + as_string(name);
    if (key in nfqws_blob_probe_cache)
        return nfqws_blob_probe_cache[key];

    let builtin = false;
    let out = command_output(command_from_args([
        as_string(bin), "--dry-run", "--qnum=65535",
        "--blob=" + as_string(name) + ":@" + as_string(probe_file),
        "--filter-tcp=443", "--filter-l7=tls", "--payload=tls_client_hello"
    ]) + " 2>&1");
    if (index(as_string(out), "duplicate blob name") >= 0)
        builtin = true;

    nfqws_blob_probe_cache[key] = builtin;
    return builtin;
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
        "ps 2>/dev/null | grep " + grep_args + " | grep -v grep | grep -v -E 'action[.]uc|updates[.]uc' | awk '{print $1}' | " +
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
    return fs.writefile(target, data) != null;
}

// The copy that never holds the payload in the ucode heap. copy_file() reads
// the whole file with fs.readfile to compare and rewrite it, which is fine for
// a ruleset and fatal for a sing-box binary: on the 256 MB router from issue
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
function singbox_config_path() {
    return getenv("TACHYON_SINGBOX_CONFIG") || "/etc/sing-box/config.json";
}

function get_mixed_inbound_info() {
    let data = fs.readfile(singbox_config_path());
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

// Reads the version out of `sing-box version` output.
//
// Taking the last whitespace-separated token of the first line assumed the
// banner ends in the version. That held for 1.13 ("sing-box version 1.13.0")
// and stopped holding once 1.14 added trailing detail:
//     sing-box 1.14.5 linux-amd64                         -> "linux-amd64"
//     sing-box version 1.14.5 (with_quic, with_tailscale) -> "with_tailscale)"
// Both then failed the caller's /^[vV]?[0-9]+/ gate and produced "". An empty
// version is not a cosmetic status problem: check_runtime_requirements() turns
// it into a fatal "Aborted.", so the apply dies and the user is left with a
// config that refuses to generate and no stated cause (TCH-1046).
//
// So match the token that follows the word "version" wherever it appears, and
// fall back to the first version-shaped token of the banner when the keyword is
// absent - never to the last token, which on a banner that puts the platform
// after the version is the platform.
// The character class is an explicit list rather than a negated one: \s includes
// \n in this regex engine, so "[^\s...]" runs past the end of the line and
// swallows the rest of the banner.
function parse_sing_box_version(output) {
    let text = as_string(output);
    let m = match(text, /sing-box[ \t]+version[ \t]+(v?[0-9][0-9A-Za-z._+-]*)/);
    if (m != null)
        return as_string(m[1]);
    m = match(text, /tachyon-core[ \t]+(v?[0-9][0-9A-Za-z._+-]*)/);
    if (m != null)
        return as_string(m[1]);
    // No "version" keyword anywhere. Take the first token of the banner that
    // is actually version-shaped rather than blindly the last one: on
    // "sing-box 1.14.5 linux-amd64" the last token is the platform, and handing
    // that back would be worse than returning nothing, because the caller's
    // /^[vV]?[0-9]+/ gate would let it through.
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
    parse_sing_box_version,
    print_file_first_line,
    section_name,
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
    int_option,
    int_or_range_option,
    bytes_to_hex,
    extended_awg_schema_has_junk_signatures,
    sing_box_supports_openvpn,
    certificate_pin_base64,
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
    nfqws_blob_is_builtin,
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
    singbox_config_path,
    get_mixed_inbound_info,
    get_mixed_port,
    get_lan_ip,
    get_mixed_proxy_endpoint,
    timeout_prefix,
    bounded_command,
    kill_matching_command,
    kill_orphaned_logread,
    ipv6_supported
};