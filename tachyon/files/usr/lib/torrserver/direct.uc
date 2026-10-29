#!/usr/bin/ucode

let fs = require("fs");
let uci = require("core.uci");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const TABLE = "TachyonTorrServerDirect";
const OUTBOUND_MARK = getenv("NFT_OUTBOUND_MARK") || "0x08000000";

function text(value) { return value == null ? "" : "" + value; }
function quote(value) { return "'" + replace(text(value), /'/g, "'\\''") + "'"; }
function command(args) {
    let values = [];
    for (let arg in args) push(values, quote(arg));
    return join(" ", values);
}
function success(args) { return system(command(args) + " >/dev/null 2>&1") == 0; }
function command_output(args) {
    let pipe = fs.popen(command(args) + " 2>/dev/null", "r");
    if (!pipe) return "";
    let data = pipe.read("all");
    let status = pipe.close();
    return status == 0 && data != null ? text(data) : "";
}
function read(path) { let value = fs.readfile(path); return value == null ? "" : text(value); }
function is_torrserver_cmdline(value) {
    value = lc(replace(text(value), /\x00/g, " "));
    return match(value, /(^|[/ ])torrserver([^/ ]*)?( |$)/) != null;
}
function numeric_pid(path) {
    let parts = split(path, "/");
    let pid = length(parts) > 2 ? parts[2] : "";
    return match(pid, /^[0-9]+$/) != null ? pid : "";
}
function process_cgroup(pid) {
    for (let line in split(read("/proc/" + pid + "/cgroup"), "\n")) {
        let match_value = match(line, /^[0-9]+::(\/.+)$/);
        if (match_value != null) return match_value[1];
    }
    return "";
}
function valid_cgroup(path) {
    if (match(path, /^\/[A-Za-z0-9_.@:-]+(\/[A-Za-z0-9_.@:-]+)+$/) == null)
        return false;
    return path != "/services" && path != "/system.slice" && path != "/user.slice";
}
function dedicated_cgroup(path) {
    let pids = split(replace(read("/sys/fs/cgroup" + path + "/cgroup.procs"), /[\r\n]+$/g, ""), /[\r\n]+/);
    let found = 0;
    for (let pid in pids) {
        if (pid == "") continue;
        found++;
        if (!is_torrserver_cmdline(read("/proc/" + pid + "/cmdline"))) return false;
    }
    return found > 0;
}
let cached_pid = "";

function discover() {
    if (cached_pid != "") {
        let cmdline_path = "/proc/" + cached_pid + "/cmdline";
        if (is_torrserver_cmdline(read(cmdline_path))) {
            let path = process_cgroup(cached_pid);
            if (valid_cgroup(path) && dedicated_cgroup(path))
                return { running: 1, available: 1, pid: cached_pid, cgroup: path };
            return { running: 1, available: 0, pid: cached_pid, cgroup: path };
        }
        cached_pid = "";
    }

    for (let cmdline_path in fs.glob("/proc/[0-9]*/cmdline")) {
        let pid = numeric_pid(cmdline_path);
        if (pid == "" || !is_torrserver_cmdline(read(cmdline_path))) continue;
        cached_pid = pid;
        let path = process_cgroup(pid);
        if (valid_cgroup(path) && dedicated_cgroup(path))
            return { running: 1, available: 1, pid, cgroup: path };
        return { running: 1, available: 0, pid, cgroup: path };
    }
    return { running: 0, available: 0, pid: "", cgroup: "" };
}
function enabled() { return trim(uci.get(CONFIG_NAME + ".settings.torrserver_direct_enabled")) == "1"; }
function rule_output_active(output, info) {
    if (!info.available) return false;
    let path = substr(info.cgroup, 1);
    let parts = split(path, "/");
    let level = length(parts) > 2 ? 2 : length(parts);
    if (level == 2) path = parts[0] + "/" + parts[1];
    return (index(output, "type route hook output priority mangle - 1") >= 0 ||
            index(output, "type route hook output priority -151") >= 0) &&
        index(output, "socket cgroupv2 level " + level + " \"" + path + "\"") >= 0 &&
        (index(output, "meta mark set 0x08000000") >= 0 ||
         index(output, "meta mark set 0x8000000") >= 0) &&
        index(output, "Tachyon TorrServer Direct") >= 0;
}
function active(info) {
    return rule_output_active(command_output([ "nft", "list", "chain", "inet", TABLE, "output" ]), info);
}
function remove_rule() { success([ "nft", "delete", "table", "inet", TABLE ]); }
function apply_rule(info) {
    if (!info.available) return false;
    let path = substr(info.cgroup, 1);
    let parts = split(path, "/");
    let level = length(parts) > 2 ? 2 : length(parts);
    if (level == 2)
        path = parts[0] + "/" + parts[1];
    remove_rule();
    let ruleset_path = "/tmp/tachyon-torrserver-direct.nft";
    let ruleset = "add table inet " + TABLE + "\n" +
        "add chain inet " + TABLE + " output { type route hook output priority -151; policy accept; }\n" +
        "add rule inet " + TABLE + " output socket cgroupv2 level " + level + " \"" + path +
        "\" meta mark set " + OUTBOUND_MARK + " counter comment \"Tachyon TorrServer Direct\"\n";
    if (fs.writefile(ruleset_path, ruleset) == null)
        return false;
    let applied = success([ "nft", "-f", ruleset_path ]);
    try { fs.unlink(ruleset_path); } catch (e) { }
    if (!applied || !active(info)) {
        remove_rule();
        return false;
    }
    return true;
}
function find_torrserver_bin() {
    for (let p in [ "/usr/bin/torrserver", "/usr/sbin/torrserver", "/opt/torrserver/torrserver", "/opt/bin/torrserver", "/tmp/torrserver/torrserver" ]) {
        let st = fs.stat(p);
        if (st != null && st.type == "file" && int(st.size || 0) > 0)
            return p;
    }
    return "";
}
function read_torrserver_version(bin_path) {
    let state_ver = trim(read("/etc/tachyon/torrserver-version"));
    if (state_ver != "")
        return state_ver;
    if (bin_path == "")
        return "not installed";
    let out = trim(command_output([ bin_path, "--version" ]));
    let m = match(out, /TorrServer\s+([^\r\n]+)/i);
    if (m != null && trim(m[1]) != "")
        return trim(m[1]);
    return out != "" ? split(out, /[\r\n]+/)[0] : "installed";
}
function status() {
    let info = discover();
    let bin = find_torrserver_bin();
    info.installed = (bin != "" || info.running == 1) ? 1 : 0;
    info.version = info.installed ? read_torrserver_version(bin) : "not installed";
    info.enabled = enabled() ? 1 : 0;
    info.active = active(info) ? 1 : 0;
    return info;
}
function reconcile() {
    if (!enabled()) { remove_rule(); return 0; }
    let info = discover();
    if (!info.available) { remove_rule(); return 1; }
    return apply_rule(info) ? 0 : 1;
}
function worker() {
    let last_cgroup = "";
    while (enabled()) {
        let info = discover();
        if (info.available && (info.cgroup != last_cgroup || !active(info))) {
            if (apply_rule(info)) last_cgroup = info.cgroup;
        }
        else if (!info.available) {
            remove_rule();
            last_cgroup = "";
        }
        if (info.available)
            sleep(60000);
        else
            sleep(5000);
    }
    remove_rule();
}

let mode = ARGV[0] || "status";
if (mode == "status") print(sprintf("%J\n", status()));
else if (mode == "reconcile") exit(reconcile());
else if (mode == "remove") { remove_rule(); exit(0); }
else if (mode == "worker") worker();
else if (mode == "rule-output-active") {
    let info = { available: 1, cgroup: ARGV[1] || "" };
    exit(rule_output_active(read("/dev/stdin"), info) ? 0 : 1);
}
else exit(1);
