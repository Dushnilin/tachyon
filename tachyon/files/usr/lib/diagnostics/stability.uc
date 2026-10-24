#!/usr/bin/env ucode
//
// Tachyon Aggregated Stability & Diagnostics Dashboard Engine (BRANCH 24):
//   1. Collects system, service, and engine uptimes.
//   2. Tracks watchdog restarts, WAN flaps, DNS failovers, component crashes,
//      and configuration rollbacks.
//   3. Monitors RAM memory pressure, swap, VmRSS per daemon, and file descriptor (FD) usage.
//   4. Detects orphaned processes and failed background jobs.
//   5. Integrates server fleet health & latency from diagnostics.server_stats.
//   6. Computes unified stability score (0-100%) and timeline of recent incidents.
//

let fs = require("fs");
let common = require("core.common");
let constants = require("core.constants");
let uci_core = require("core.uci");

let as_string = common.as_string;
let command_capture = common.command_capture;
let command_output_from_args = common.command_output_from_args;
let write_json_file = common.write_json_file;
let read_json_file = common.read_json_file;

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const TACHYON_BIN = getenv("TACHYON_BIN") || "/usr/bin/tachyon";

// --- Safe Helpers ---

function safe_json_parse(text) {
    if (text == null || text == "") return null;
    try {
        return json(text);
    } catch (e) {
        return null;
    }
}

function safe_read_file(path) {
    if (!path || !fs.stat(path)) return "";
    let content = fs.readfile(path);
    return content != null ? trim(as_string(content)) : "";
}

function format_duration_pretty(total_seconds) {
    let sec = int(total_seconds) || 0;
    if (sec <= 0) return "0s";

    let days = int(sec / 86400);
    sec %= 86400;
    let hours = int(sec / 3600);
    sec %= 3600;
    let mins = int(sec / 60);
    let rem_sec = sec % 60;

    let parts = [];
    if (days > 0) push(parts, sprintf("%dd", days));
    if (hours > 0) push(parts, sprintf("%dh", hours));
    if (mins > 0) push(parts, sprintf("%dm", mins));
    if (length(parts) == 0 || (days == 0 && hours == 0 && rem_sec > 0))
        push(parts, sprintf("%ds", rem_sec));

    return join(" ", parts);
}

// --- System & Process Uptimes ---

function get_system_uptime() {
    let content = safe_read_file("/proc/uptime");
    let parts = split(content, /[ \t]+/);
    let sec = 0;
    if (length(parts) > 0) {
        sec = int(parts[0]) || 0;
    }
    return {
        seconds: sec,
        pretty: format_duration_pretty(sec)
    };
}

function get_process_uptime(pid) {
    if (!pid || int(pid) <= 0) return null;
    let stat_raw = safe_read_file("/proc/" + pid + "/stat");
    let uptime_raw = safe_read_file("/proc/uptime");
    if (stat_raw != "" && uptime_raw != "") {
        let rpar = rindex(stat_raw, ")");
        if (rpar > 0) {
            let tail = split(trim(substr(stat_raw, rpar + 1)), /[ \t]+/);
            if (length(tail) >= 20) {
                let start_sec = int(int(tail[19]) / 100);
                let sys_sec = int(split(trim(uptime_raw), /[ \t]+/)[0]);
                let uptime = sys_sec - start_sec;
                if (uptime < 0) uptime = 0;
                return {
                    pid: int(pid),
                    started_at: time() - uptime,
                    uptime_seconds: uptime,
                    pretty: format_duration_pretty(uptime)
                };
            }
        }
    }
    let st = fs.stat("/proc/" + pid);
    if (!st || !st.mtime) return null;
    let now = time();
    let uptime = now - st.mtime;
    if (uptime < 0) uptime = 0;
    return {
        pid: int(pid),
        started_at: st.mtime,
        uptime_seconds: uptime,
        pretty: format_duration_pretty(uptime)
    };
}

let cached_proc_map = null;

function scan_proc_comm_map() {
    if (cached_proc_map != null)
        return cached_proc_map;
    cached_proc_map = {};
    let proc_dir = fs.opendir("/proc");
    if (proc_dir) {
        let ent;
        while ((ent = proc_dir.read()) != null) {
            if (match(ent, /^[0-9]+$/)) {
                let comm = safe_read_file("/proc/" + ent + "/comm");
                if (comm != "") {
                    if (!cached_proc_map[comm])
                        cached_proc_map[comm] = [];
                    push(cached_proc_map[comm], ent);
                }
            }
        }
        proc_dir.close();
    }
    return cached_proc_map;
}

function get_daemon_pids(name) {
    let pmap = scan_proc_comm_map();

    if (name == "tachyon-core" || name == "sing-box") {
        let pids = [];
        let seen = {};
        let proc = require("core.process");
        for (let path in proc.core_contract().pid_files) {
            let val = safe_read_file(path);
            if (val != "" && match(val, /^[0-9]+$/) && proc.exe_basename(val) == name && !proc.is_core_initscript(val)) {
                push(pids, val);
                seen[val] = true;
            }
        }
        for (let pid in proc.core_daemon_pids()) {
            if (!seen[pid] && proc.exe_basename(pid) == name) {
                push(pids, pid);
                seen[pid] = true;
            }
        }
        for (let pid in (pmap[name] || [])) {
            if (!seen[pid]) {
                let cmd = safe_read_file("/proc/" + pid + "/cmdline");
                if (index(cmd, "run") >= 0 && index(cmd, "check") < 0) {
                    push(pids, pid);
                    seen[pid] = true;
                }
            }
        }
        return pids;
    }

    if (name == "tachyon") {
        let pids = [];
        let seen = {};
        let pidfiles = [
            "/var/run/tachyon/dns-failover.pid",
            "/var/run/tachyon/priority.pid",
            "/var/run/tachyon-feedback.pid",
            "/var/run/tachyon/fuzzer-worker.pid"
        ];
        for (let pf in pidfiles) {
            let val = safe_read_file(pf);
            if (val != "" && match(val, /^[0-9]+$/) && fs.stat("/proc/" + val) != null) {
                push(pids, val);
                seen[val] = true;
            }
        }
        let self_stat = safe_read_file("/proc/self/stat");
        let self_pid = split(self_stat, /[ \t]+/)[0] || "";
        for (let pid in (pmap["ucode"] || [])) {
            if (seen[pid] || pid == self_pid) continue;
            let cmd = safe_read_file("/proc/" + pid + "/cmdline");
            if (index(cmd, "/usr/lib/tachyon/") >= 0 &&
                index(cmd, "tachyon_entry.uc") < 0 &&
                index(cmd, "service/ui.uc") < 0 &&
                index(cmd, "diagnostics/stability.uc") < 0 &&
                index(cmd, "watchdog.uc") < 0 &&
                index(cmd, "telegram.uc") < 0) {
                push(pids, pid);
                seen[pid] = true;
            }
        }
        return pids;
    }

    if (name == "watchdog") {
        let pids = [];
        let seen = {};
        for (let pf in [ "/var/run/tachyon_watchdog.pid", "/var/run/tachyon_watchdog.supervisor.pid" ]) {
            let val = safe_read_file(pf);
            if (val != "" && match(val, /^[0-9]+$/) && fs.stat("/proc/" + val) != null) {
                let comm = safe_read_file("/proc/" + val + "/comm");
                if (comm == "ucode" || comm == "sh") {
                    push(pids, val);
                    seen[val] = true;
                }
            }
        }
        for (let pid in (pmap["ucode"] || [])) {
            if (!seen[pid] && index(safe_read_file("/proc/" + pid + "/cmdline"), "watchdog.uc") >= 0) {
                push(pids, pid);
                seen[pid] = true;
            }
        }
        return pids;
    }

    if (name == "telegram") {
        let pids = [];
        let seen = {};
        let val = safe_read_file("/var/run/tachyon_telegram.pid");
        if (val != "" && match(val, /^[0-9]+$/) && fs.stat("/proc/" + val) != null) {
            push(pids, val);
            seen[val] = true;
        }
        for (let pid in (pmap["ucode"] || [])) {
            if (!seen[pid] && index(safe_read_file("/proc/" + pid + "/cmdline"), "telegram.uc") >= 0) {
                push(pids, pid);
                seen[pid] = true;
            }
        }
        return pids;
    }

    if (name == "dnsmasq") {
        let pids = [];
        let all = pmap["dnsmasq"] || [];
        for (let pid in all) {
            let cmd = safe_read_file("/proc/" + pid + "/cmdline");
            if (index(cmd, "ujail") < 0)
                push(pids, pid);
        }
        if (length(pids) == 0 && length(all) > 0)
            pids = all;
        return pids;
    }

    if (name == "steer") {
        let pids = [];
        let seen = {};
        let val = safe_read_file("/var/run/steer.pid");
        if (val != "" && match(val, /^[0-9]+$/) && fs.stat("/proc/" + val) != null) {
            push(pids, val);
            seen[val] = true;
        }
        for (let pid in (pmap["steer"] || [])) {
            if (!seen[pid]) {
                push(pids, pid);
                seen[pid] = true;
            }
        }
        return pids;
    }

    if (name == "wdtt") {
        let pids = [];
        for (let comm_name in [ "qwdtt-client", "qwdtt", "wdtt" ]) {
            for (let pid in (pmap[comm_name] || []))
                push(pids, pid);
        }
        return pids;
    }

    if (name == "fptn") {
        let pids = [];
        let seen = {};
        let val = safe_read_file("/var/run/tachyon/fptn/fptn.pid");
        if (val != "" && match(val, /^[0-9]+$/) && fs.stat("/proc/" + val) != null) {
            push(pids, val);
            seen[val] = true;
        }
        for (let comm_name in [ "fptn-client-cli", "fptn-client" ]) {
            for (let pid in (pmap[comm_name] || [])) {
                if (!seen[pid]) {
                    push(pids, pid);
                    seen[pid] = true;
                }
            }
        }
        return pids;
    }

    if (name == "tailscale") {
        return pmap["tailscaled"] || [];
    }

    if (name == "sing-box") {
        let pids = [];
        let seen = {};
        for (let p in (pmap["sing-box"] || [])) {
            push(pids, p);
            seen[p] = true;
        }
        let marker = safe_read_file(constants.SB_VARIANT_STATE_FILE || "/etc/tachyon/tachyon-core-variant");
        if (marker == "" && getenv("SB_VARIANT_STATE_FILE") == null)
            marker = safe_read_file("/etc/tachyon/sing-box-variant");
        if (marker != "tachyon-core") {
            for (let p in (pmap["tachyon-core"] || [])) {
                if (!seen[p]) {
                    push(pids, p);
                    seen[p] = true;
                }
            }
        }
        return pids;
    }

    return pmap[name] || [];
}

function find_named_pid(name) {
    let pids = get_daemon_pids(name);
    return length(pids) > 0 ? pids[0] : "";
}

function get_relevant_daemons() {
    let cfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
    let tg_cfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
    let sections = uci_core.section_objects(CONFIG_NAME, "section") || [];
    let servers = uci_core.section_objects(CONFIG_NAME, "server") || [];

    let active_engine = "tachyon-core";
    try {
        active_engine = require("core.engine").get_active();
    } catch (e) {}

    let is_steer = (active_engine == "steer" || active_engine == "steer-extended");
    let list = [];

    if (is_steer) {
        push(list, "steer");
    } else {
        let marker = safe_read_file(constants.SB_VARIANT_STATE_FILE || "/etc/tachyon/tachyon-core-variant");
        if (marker == "" && getenv("SB_VARIANT_STATE_FILE") == null)
            marker = safe_read_file("/etc/tachyon/sing-box-variant");
        let is_core = (marker == "tachyon-core");
        push(list, is_core ? "tachyon-core" : "sing-box");
    }

    if (length(get_daemon_pids("tachyon")) > 0)
        push(list, "tachyon");

    if (cfg.enable_watchdog != "0" || length(get_daemon_pids("watchdog")) > 0)
        push(list, "watchdog");

    if (tg_cfg.enabled == "1" || length(get_daemon_pids("telegram")) > 0)
        push(list, "telegram");

    let has_action = function(act) {
        for (let s in sections) {
            if (s.enabled != "0" && s.action == act)
                return true;
        }
        return false;
    };

    let has_bin = function(paths) {
        for (let p in paths) {
            if (p && fs.stat(p) != null)
                return true;
        }
        return false;
    };

    if ((has_action("zapret2") && has_bin([ constants.ZAPRET2_PROVIDER_NFQWS2_BIN, "/opt/zapret2/nfq2/nfqws2", "/usr/bin/nfqws2" ])) || length(get_daemon_pids("nfqws2")) > 0)
        push(list, "nfqws2");

    if ((has_action("zapret") && has_bin([ constants.ZAPRET_PROVIDER_NFQWS_BIN, "/opt/zapret/nfq/nfqws", "/usr/bin/nfqws" ])) || length(get_daemon_pids("nfqws")) > 0)
        push(list, "nfqws");

    if ((has_action("byedpi") && has_bin([ constants.BYEDPI_BIN, "/usr/bin/ciadpi" ])) || length(get_daemon_pids("ciadpi")) > 0)
        push(list, "ciadpi");

    if ((has_action("wdtt") && has_bin([ "/usr/bin/qwdtt-client", "/usr/bin/qwdtt", "/usr/bin/wdtt" ])) || length(get_daemon_pids("wdtt")) > 0)
        push(list, "wdtt");

    if ((has_action("olcrtc") && has_bin([ "/usr/bin/olcrtc" ])) || length(get_daemon_pids("olcrtc")) > 0)
        push(list, "olcrtc");

    if ((has_action("fptn") && has_bin([ "/usr/bin/fptn-client-cli", "/usr/bin/fptn-client" ])) || length(get_daemon_pids("fptn")) > 0)
        push(list, "fptn");

    let has_native_ts = false;
    for (let srv in servers) {
        if (srv.enabled != "0" && srv.protocol == "tailscale" && srv.tailscale_mode == "native") {
            has_native_ts = true;
            break;
        }
    }
    if ((has_native_ts && has_bin([ "/usr/sbin/tailscaled", "/usr/bin/tailscaled" ])) || length(get_daemon_pids("tailscale")) > 0)
        push(list, "tailscale");

    push(list, "dnsmasq");
    if (length(get_daemon_pids("AdGuardHome")) > 0)
        push(list, "AdGuardHome");

    return list;
}

function get_daemon_uptimes() {
    let daemons = get_relevant_daemons();
    let result = {};

    for (let d in daemons) {
        let pids = get_daemon_pids(d);
        if (length(pids) > 0) {
            let best_u = null;
            let pid_nums = [];
            for (let p in pids) {
                push(pid_nums, int(p));
                let u = get_process_uptime(p);
                if (u && (best_u == null || u.uptime_seconds > best_u.uptime_seconds))
                    best_u = u;
            }
            if (best_u) {
                result[d] = {
                    running: true,
                    pid: int(pids[0]),
                    pids: pid_nums,
                    workers: length(pid_nums),
                    uptime_seconds: best_u.uptime_seconds,
                    pretty: best_u.pretty
                };
            } else {
                result[d] = {
                    running: true,
                    pid: int(pids[0]),
                    pids: pid_nums,
                    workers: length(pid_nums),
                    uptime_seconds: 0,
                    pretty: "0s"
                };
            }
        } else {
            result[d] = { running: false, pid: null, pids: [], workers: 0, uptime_seconds: 0, pretty: "stopped" };
        }
    }
    return result;
}

// --- Memory & Resource Pressure ---

function get_memory_pressure() {
    let meminfo = safe_read_file("/proc/meminfo");
    let total = 0;
    let free = 0;
    let available = 0;
    let buffers = 0;
    let cached = 0;
    let swap_total = 0;
    let swap_free = 0;

    for (let line in split(meminfo, "\n")) {
        let m = match(line, /^([A-Za-z0-9_()]+):\s+([0-9]+)\s+kB/);
        if (m) {
            let k = m[1];
            let v = int(m[2]) || 0;
            if (k == "MemTotal") total = v;
            else if (k == "MemFree") free = v;
            else if (k == "MemAvailable") available = v;
            else if (k == "Buffers") buffers = v;
            else if (k == "Cached") cached = v;
            else if (k == "SwapTotal") swap_total = v;
            else if (k == "SwapFree") swap_free = v;
        }
    }

    if (available == 0 && total > 0) {
        available = free + buffers + cached;
    }

    let used = total > available ? total - available : 0;
    let used_pct = total > 0 ? int((used * 100) / total) : 0;

    let pressure = "normal";
    if (used_pct >= 90) pressure = "critical";
    else if (used_pct >= 75) pressure = "warning";

    // VmRSS per daemon (de-duplicating shared RssFile across multi-worker daemons)
    let daemons = get_relevant_daemons();
    let daemon_rss = {};
    for (let d in daemons) {
        let pids = get_daemon_pids(d);
        if (length(pids) > 0) {
            let sum_anon = 0;
            let max_file = 0;
            let sum_vmrss = 0;
            let has_breakdown = false;
            for (let pid in pids) {
                let status = safe_read_file("/proc/" + pid + "/status");
                let anon_m = match(status, /RssAnon:[ \t]+([0-9]+)\s+kB/);
                let file_m = match(status, /RssFile:[ \t]+([0-9]+)\s+kB/);
                let shmem_m = match(status, /RssShmem:[ \t]+([0-9]+)\s+kB/);
                let rm = match(status, /VmRSS:[ \t]+([0-9]+)\s+kB/);
                if (anon_m && file_m) {
                    has_breakdown = true;
                    sum_anon += (int(anon_m[1]) || 0) + (shmem_m ? (int(shmem_m[1]) || 0) : 0);
                    let rf = int(file_m[1]) || 0;
                    if (rf > max_file) max_file = rf;
                } else if (rm) {
                    sum_vmrss += int(rm[1]) || 0;
                }
            }
            daemon_rss[d] = has_breakdown ? (sum_anon + max_file) : sum_vmrss;
        }
    }

    return {
        total_kb: total,
        free_kb: free,
        available_kb: available,
        used_kb: used,
        used_pct: used_pct,
        pressure_level: pressure,
        swap_total_kb: swap_total,
        swap_free_kb: swap_free,
        swap_used_kb: swap_total > swap_free ? swap_total - swap_free : 0,
        daemons_rss_kb: daemon_rss
    };
}

// --- File Descriptors & Orphan Detection ---

function get_fd_stats() {
    let fnr = safe_read_file("/proc/sys/fs/file-nr");
    let parts = split(fnr, /[ \t]+/);
    let allocated = 0;
    let max = 0;
    if (length(parts) >= 3) {
        allocated = int(parts[0]) || 0;
        max = int(parts[2]) || 0;
    }

    let daemons = get_relevant_daemons();
    let daemon_fds = {};
    for (let d in daemons) {
        let pids = get_daemon_pids(d);
        if (length(pids) > 0) {
            let fds = 0;
            for (let pid in pids) {
                let fd_dir = fs.opendir("/proc/" + pid + "/fd");
                if (fd_dir) {
                    let ent;
                    while ((ent = fd_dir.read()) != null) {
                        if (ent != "." && ent != "..") fds++;
                    }
                    fd_dir.close();
                }
            }
            daemon_fds[d] = fds;
        }
    }

    return {
        system_allocated: allocated,
        system_max: max,
        system_used_pct: max > 0 ? int((allocated * 100) / max) : 0,
        daemons: daemon_fds
    };
}

function get_orphan_processes() {
    let orphans = [];
    let tracked = [ "curl", "nfqws", "nfqws2", "ciadpi" ];
    let proc_dir = fs.opendir("/proc");
    if (proc_dir) {
        let ent;
        while ((ent = proc_dir.read()) != null) {
            if (match(ent, /^[0-9]+$/)) {
                let comm = safe_read_file("/proc/" + ent + "/comm");
                for (let t in tracked) {
                    if (comm == t) {
                        let stat_raw = safe_read_file("/proc/" + ent + "/stat");
                        let sparts = split(stat_raw, /[ \t]+/);
                        // Field 4 is PPID in /proc/<pid>/stat
                        if (length(sparts) >= 4) {
                            let ppid = int(sparts[3]) || 0;
                            // Check if orphaned to PID 1 without being an active daemon
                            if (ppid == 1 && t == "curl") {
                                push(orphans, { pid: int(ent), comm: comm, ppid: ppid });
                            }
                        }
                    }
                }
            }
        }
        proc_dir.close();
    }
    return {
        count: length(orphans),
        orphans: orphans
    };
}

// --- Restarts, Flaps and Incident Timeline ---

function analyze_incidents_and_logs() {
    let wan_flaps = 0;
    let watchdog_restarts = 0;
    let engine_crashes = 0;
    let dnsmasq_restarts = 0;
    let dns_failovers = 0;
    let config_rollbacks = 0;
    let recent_incidents = [];

    // 1. Inspect Event Journal if present
    try {
        let ev_mod = require("core.events");
        if (ev_mod && ev_mod.journal) {
            let j = ev_mod.journal();
            let entries = j.tail(100);
            if (type(entries) == "array") {
                for (let ev in entries) {
                    let name = as_string(ev.event || "");
                    let sev = as_string(ev.severity || "");
                    if (index(name, "wan_down") >= 0 || index(name, "wan_flap") >= 0)
                        wan_flaps++;
                    if (index(name, "watchdog_restart") >= 0 || index(name, "crashed") >= 0)
                        watchdog_restarts++;
                    if (index(name, "dns_failover") >= 0)
                        dns_failovers++;
                    if (index(name, "rollback") >= 0)
                        config_rollbacks++;

                    if (sev == "warning" || sev == "error" || sev == "crit" || index(name, "rollback") >= 0 || index(name, "failover") >= 0) {
                        push(recent_incidents, {
                            time: ev.ts || time(),
                            source: ev.source || "system",
                            severity: sev || "warning",
                            title: name,
                            message: ev.message || ""
                        });
                    }
                }
            }
        }
    } catch (e) {}

    // 2. Cross-reference recent syslog for system-level triggers
    let hist = command_capture("logread 2>/dev/null | tail -n 250").output;
    for (let line in split(hist, "\n")) {
        let l = lc(line);
        if (index(l, "successful component change") >= 0 || index(l, "upgrading") >= 0 ||
            index(l, "post-upgrade") >= 0 || index(l, "doctor_fix") >= 0)
            continue;

        if (index(l, "udhcpc") >= 0 && (index(l, "lease lost") >= 0 || index(l, "deconfig") >= 0))
            wan_flaps++;
        if (index(l, "wan.down") >= 0 || index(l, "watchdog: wan check failed") >= 0)
            wan_flaps++;
        if ((index(l, "sing-box") >= 0 || index(l, "tachyon-core") >= 0 || index(l, "steer") >= 0) &&
            (index(l, "panic:") >= 0 || index(l, "fatal error:") >= 0 || index(l, "sigsegv") >= 0 || index(l, "died unexpectedly") >= 0))
            engine_crashes++;
        if (index(l, "dnsmasq") >= 0 &&
            (index(l, "failed to create listening socket") >= 0 || index(l, "address already in use") >= 0 || index(l, "failed to start") >= 0))
            dnsmasq_restarts++;
        if (index(l, "watchdog: crashed") >= 0 || index(l, "tachyon_watchdog") >= 0 && index(l, "died") >= 0)
            watchdog_restarts++;
    }

    return {
        wan_flaps: wan_flaps,
        watchdog_restarts: watchdog_restarts,
        engine_crashes: engine_crashes,
        dnsmasq_restarts: dnsmasq_restarts,
        dns_failovers: dns_failovers,
        config_rollbacks: config_rollbacks,
        recent_incidents: recent_incidents
    };
}

// --- Jobs Metrics ---

function get_jobs_metrics() {
    let total = 0;
    let running = 0;
    let failed = 0;
    let cancelled = 0;
    let last_failed = null;

    try {
        let jobs_mod = require("core.jobs");
        if (jobs_mod && jobs_mod.list_jobs) {
            let all = jobs_mod.list_jobs({ all: true });
            if (type(all) == "array") {
                total = length(all);
                for (let job in all) {
                    let phase = as_string(job.phase || "");
                    if (phase == "running" || phase == "preflight" || phase == "created")
                        running++;
                    else if (phase == "failed") {
                        failed++;
                        if (last_failed == null || (job.updated_at && job.updated_at > last_failed.updated_at))
                            last_failed = job;
                    } else if (phase == "cancelled") {
                        cancelled++;
                    }
                }
            }
        }
    } catch (e) {}

    return {
        total_jobs: total,
        running_jobs: running,
        failed_jobs: failed,
        cancelled_jobs: cancelled,
        last_failed_job: last_failed
    };
}

// --- Server Fleet Health ---

function get_server_fleet_stats() {
    try {
        let stats_mod = require("diagnostics.server_stats");
        if (stats_mod && stats_mod.get_summary) {
            let sum = stats_mod.get_summary();
            return {
                total_servers: sum.total_servers || 0,
                healthy_count: sum.healthy_count || 0,
                unhealthy_count: sum.unhealthy_count || 0,
                untested_count: sum.untested_count || 0,
                avg_latency_ms: sum.avg_latency_ms || 0,
                best_server: sum.best_server,
                sections: sum.sections || {}
            };
        }
    } catch (e) {}

    return {
        total_servers: 0,
        healthy_count: 0,
        unhealthy_count: 0,
        untested_count: 0,
        avg_latency_ms: 0,
        best_server: null,
        sections: {}
    };
}

// --- Stability Score Calculation ---

function compute_stability_score(incidents, memory, servers, jobs, daemons) {
    let score = 100;
    let penalties = [];

    // 1. Process health: engine and (if enabled) watchdog must be running
    if (!daemons["tachyon-core"]?.running && !daemons["sing-box"]?.running && !daemons["steer"]?.running) {
        score -= 40;
        push(penalties, "Routing engine is not running (-40)");
    }
    if (daemons["watchdog"] != null && !daemons["watchdog"].running) {
        score -= 15;
        push(penalties, "Watchdog daemon is stopped (-15)");
    }

    // 2. Incidents & Flaps
    if (incidents.wan_flaps > 0) {
        let p = incidents.wan_flaps * 5;
        if (p > 25) p = 25;
        score -= p;
        push(penalties, sprintf("WAN flaps detected: %d (-%d)", incidents.wan_flaps, p));
    }
    if (incidents.watchdog_restarts > 0) {
        let p = incidents.watchdog_restarts * 10;
        if (p > 30) p = 30;
        score -= p;
        push(penalties, sprintf("Watchdog recoveries: %d (-%d)", incidents.watchdog_restarts, p));
    }
    if (incidents.engine_crashes > 0) {
        let p = incidents.engine_crashes * 15;
        if (p > 30) p = 30;
        score -= p;
        push(penalties, sprintf("Engine crashes detected: %d (-%d)", incidents.engine_crashes, p));
    }

    // 3. Memory Pressure
    if (memory.pressure_level == "critical") {
        score -= 20;
        push(penalties, sprintf("Critical RAM pressure (%d%% used) (-20)", memory.used_pct));
    } else if (memory.pressure_level == "warning") {
        score -= 10;
        push(penalties, sprintf("High RAM pressure (%d%% used) (-10)", memory.used_pct));
    }

    // 4. Server Fleet Health
    if (servers.total_servers > 0) {
        if (servers.healthy_count == 0 && servers.unhealthy_count > 0) {
            score -= 25;
            push(penalties, "All proxy servers are failing (-25)");
        } else if (servers.unhealthy_count > servers.healthy_count) {
            score -= 10;
            push(penalties, sprintf("Majority of servers unhealthy (%d/%d) (-10)", servers.unhealthy_count, servers.total_servers));
        }
    }

    // 5. Failed Jobs
    if (jobs.failed_jobs > 0) {
        let p = jobs.failed_jobs * 3;
        if (p > 15) p = 15;
        score -= p;
        push(penalties, sprintf("Failed background jobs: %d (-%d)", jobs.failed_jobs, p));
    }

    if (score < 0) score = 0;

    let grade = "optimal";
    if (score < 50) grade = "critical";
    else if (score < 80) grade = "degraded";
    else if (score < 95) grade = "healthy";

    return {
        score: score,
        grade: grade,
        penalties: penalties
    };
}

// --- Main Report & Status Builders ---

function get_stability_report() {
    cached_proc_map = null;
    let sys_uptime = get_system_uptime();
    let daemons = get_daemon_uptimes();
    let memory = get_memory_pressure();
    let fd_stats = get_fd_stats();
    let orphans = get_orphan_processes();
    let incidents = analyze_incidents_and_logs();
    let jobs = get_jobs_metrics();
    let servers = get_server_fleet_stats();

    let score_info = compute_stability_score(incidents, memory, servers, jobs, daemons);

    return {
        timestamp: time(),
        health: {
            score: score_info.score,
            grade: score_info.grade,
            penalties: score_info.penalties
        },
        uptimes: {
            system: sys_uptime,
            daemons: daemons
        },
        restarts_and_flaps: {
            wan_flaps: incidents.wan_flaps,
            watchdog_restarts: incidents.watchdog_restarts,
            engine_crashes: incidents.engine_crashes,
            dnsmasq_restarts: incidents.dnsmasq_restarts,
            dns_failovers: incidents.dns_failovers,
            config_rollbacks: incidents.config_rollbacks
        },
        resources: {
            memory: memory,
            file_descriptors: fd_stats,
            orphans: orphans
        },
        jobs: jobs,
        server_fleet: servers,
        recent_incidents: incidents.recent_incidents
    };
}

function get_stability_status() {
    let rep = get_stability_report();
    return {
        timestamp: rep.timestamp,
        score: rep.health.score,
        grade: rep.health.grade,
        system_uptime: rep.uptimes.system.pretty,
        wan_flaps: rep.restarts_and_flaps.wan_flaps,
        watchdog_restarts: rep.restarts_and_flaps.watchdog_restarts,
        memory_used_pct: rep.resources.memory.used_pct,
        memory_pressure: rep.resources.memory.pressure_level,
        healthy_servers: rep.server_fleet.healthy_count,
        total_servers: rep.server_fleet.total_servers,
        avg_latency_ms: rep.server_fleet.avg_latency_ms
    };
}

function module_exports() {
    return {
        get_stability_report,
        get_stability_status
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

// --- CLI Dispatcher ---

let mode = ARGV[0];
if (mode == "status") {
    print(sprintf("%J\n", get_stability_status()));
    exit(0);
} else if (mode == "report" || mode == "" || mode == null) {
    print(sprintf("%J\n", get_stability_report()));
    exit(0);
} else {
    warn("Usage: stability.uc <status|report>\n");
    exit(1);
}

