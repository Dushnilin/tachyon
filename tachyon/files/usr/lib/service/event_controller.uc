#!/usr/bin/env ucode
//
// Event controller: the single place that observes the system and turns
// observations into facts on the event bus. It never repairs anything —
// remediation lives in service/watchdog.uc, which subscribes to these facts.
//
// Two kinds of source feed the bus:
//
//   push  — the kernel or procd tells us something happened (ubus service
//           events, syslog lines, the honeypot FIFO). Zero cost when idle.
//   probe — nothing pushes "DNS stopped resolving", so a probe tier asks.
//           Probing lives here, in one loop, instead of being duplicated
//           inside every healer: one tick collects each observation exactly
//           once and publishes it, where the old code called is_dns_working()
//           from two healers and get_sing_box_pid() from eight.
//
// Probe tiers and their intervals are unchanged from the timer-based
// watchdog: fast 15s, normal adaptive 120/300s, slow 300s.

let fs = require("fs");
let uci_core = require("core.uci");
let common = require("core.common");
let helpers = require("core.helpers");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";

// Minimum spacing between two increments of the DNS stall streak. Matches the
// floor of the old adaptive normal tier (120s), which is the rate at which
// ai_heal_dns() used to step that counter before probing moved to the fast tier.
const DNS_STREAK_INTERVAL = 120;

let as_string = common.as_string;
let shell_quote = common.shell_quote;
let command_from_args = common.command_from_args;
let command_success_from_args = common.command_success_from_args;
let is_process_name_running = helpers.is_process_name_running;

// ─── Event type vocabulary ────────────────────────────────────────────────────
// Every fact the controller can publish. Subscribers reference these constants
// rather than bare strings so a typo is a load-time error, not silent silence.
const EV = {
    SINGBOX_STOPPED:        "singbox.stopped",
    FIREWALL_RELOADED:      "firewall.reloaded",
    OOM_DETECTED:           "oom.detected",
    OOM_RECOVERABLE:        "oom.recoverable",
    SMARTDETECT_CANDIDATE:  "smartdetect.candidate",
    URLTEST_SWITCHED:       "urltest.switched",
    HONEYPOT_HIT:           "honeypot.hit",
    PROXY_DOWN:             "proxy.down",
    PROXY_UP:               "proxy.up",
    DNS_DOWN:               "dns.down",
    DNS_UP:                 "dns.up",
    MEMORY_LOW:             "memory.low",
    NFT_MISSING:            "nft.missing",
    QOS_MISSING:            "qos.missing",
    TPROXY_DOWN:            "tproxy.down",
    RPCD_FD_LEAK:           "rpcd.fd_leak",
    WAN_DOWN:               "wan.down",
    WAN_UP:                 "wan.up",
    SUBNETS_EMPTY:          "subnets.empty",
    SUBSCRIPTION_UNREACHABLE: "subscription.unreachable",
    CONFIG_CORRUPT:         "config.corrupt",
    SECTIONS_EMPTY:         "sections.empty",
    ANOMALY_RECONNECTS:     "anomaly.reconnects",
    PAUSE_EXPIRED:          "pause.expired",
    TICK:                   "tick"
};

// ─── Shell helpers ────────────────────────────────────────────────────────────
function command_capture(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return { status: 1, output: "" };
    let data = pipe.read("all");
    let status = pipe.close();
    if (status > 255) status = int(status / 256);
    return { status, output: data == null ? "" : as_string(data) };
}

function command_output_from_args(args) {
    let result = command_capture(command_from_args(args) + " 2>/dev/null");
    return result.status == 0 ? result.output : "";
}

function settings() {
    return common.object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
}

function setting(key, default_val) {
    let cfg = settings();
    let val = cfg[key];
    return val != null ? as_string(val) : as_string(default_val);
}

function enabled(key, default_val) {
    return setting(key, default_val) == "1";
}

function process_running(pid, expected_name) {
    if (match(as_string(pid), /^[0-9]+$/) == null)
        return false;
    if (expected_name != null && expected_name != "")
        return is_process_name_running(pid, expected_name);
    return fs.stat("/proc/" + pid) != null;
}

// ─── Shared observations ──────────────────────────────────────────────────────
// Resolved once per tick and handed to every probe that needs them. This is
// what removes the repeated get_sing_box_pid() / is_dns_working() calls that
// the per-healer detection prologues used to make.

function get_sing_box_pid() {
    for (let path in [ "/var/run/sing-box.pid", "/var/run/sing-box/sing-box.pid" ]) {
        let pid = trim(fs.readfile(path) || "");
        if (pid != "" && process_running(pid, "sing-box")) return pid;
    }

    let ubus_res = command_capture("ubus call service list '{\"name\":\"sing-box\"}' 2>/dev/null");
    if (ubus_res.status == 0 && ubus_res.output != "") {
        let matched = match(ubus_res.output, /"pid":\s*([0-9]+)/);
        if (matched && matched[1] != "") {
            let pid = matched[1];
            if (process_running(pid, "sing-box")) return pid;
        }
    }

    let pidof_res = command_capture("pidof sing-box 2>/dev/null");
    if (pidof_res.status == 0 && pidof_res.output != "") {
        let fields = split(trim(pidof_res.output), /[ \t]+/);
        if (length(fields) > 0 && fields[0] != "") {
            let pid = fields[0];
            if (process_running(pid, "sing-box")) return pid;
        }
    }

    return "";
}

// Scans /proc for a sing-box executable. Slower than get_sing_box_pid(), used
// only to confirm a suspected stop before publishing the fact.
function sing_box_in_proc() {
    let proc = fs.opendir("/proc");
    if (!proc) return "";
    let entry;
    let pid = "";
    while ((entry = proc.read()) != null) {
        if (match(entry, /^[0-9]+$/)) {
            let exe = fs.readlink("/proc/" + entry + "/exe") || "";
            let slash = rindex(exe, "/");
            if ((slash >= 0 ? substr(exe, slash + 1) : exe) == "sing-box") {
                pid = entry;
                break;
            }
        }
    }
    proc.close();
    return pid;
}

function is_dns_working() {
    return command_success_from_args([ "nslookup", "-timeout=2", "yandex.ru", "127.0.0.1" ]) ||
           command_success_from_args([ "nslookup", "-timeout=2", "connectivitycheck.gstatic.com", "127.0.0.1" ]) ||
           command_success_from_args([ "nslookup", "-timeout=2", "google.com", "127.0.0.1" ]);
}

function check_tachyon_cli_running() {
    let running = false;
    let proc = fs.opendir("/proc");
    if (proc) {
        let entry;
        while ((entry = proc.read()) != null) {
            if (match(entry, /^[0-9]+$/)) {
                let cmdline = fs.readfile("/proc/" + entry + "/cmdline") || "";
                if (index(cmdline, "/usr/bin/tachyon") >= 0) {
                    if (index(cmdline, "start") >= 0 || index(cmdline, "restart") >= 0 ||
                        index(cmdline, "reload") >= 0 || index(cmdline, "stop") >= 0) {
                        running = true;
                        break;
                    }
                }
            }
        }
        proc.close();
    }
    return running;
}

function is_list_update_running() {
    let pid = trim(fs.readfile("/var/run/tachyon_list_update.pid") || "");
    return process_running(pid, "ucode");
}

function is_reload_in_progress() {
    return fs.stat("/var/run/tachyon.reload.lock") != null || check_tachyon_cli_running();
}

// Reads a port out of the generated sing-box config. Both callers fall back to
// a compiled-in default when the file cannot be parsed, and that fallback is
// worth a log line: a watchdog probing 4534 while sing-box listens elsewhere
// reports the proxy as down forever and heals it in a loop. The failure used to
// be swallowed by an empty catch, so the symptom was a permanently unhealthy
// proxy with nothing in the log to connect it to the config.
//
// Logged once per process — these are called on every tick, and a config that
// fails to parse fails to parse every time.
let sb_config_parse_reported = false;

function parse_singbox_config() {
    let data = fs.readfile("/etc/sing-box/config.json");
    if (data == null)
        return null;

    try {
        return json(data);
    }
    catch (e) {
        if (!sb_config_parse_reported) {
            sb_config_parse_reported = true;
            command_success_from_args([ "logger", "-t", "tachyon",
                "[err] Watchdog: /etc/sing-box/config.json is unparseable (" + as_string(e) +
                "); falling back to default inbound ports, proxy checks may probe the wrong port" ]);
        }
        return null;
    }
}

// Reads the http/mixed inbound port from the generated sing-box config.
// Cached because the config only changes across a reload.
let cached_proxy_port = null;
function proxy_port() {
    if (cached_proxy_port !== null)
        return as_string(cached_proxy_port);

    let port = "4534";
    let sb_cfg = parse_singbox_config();
    if (sb_cfg && sb_cfg.inbounds) {
        for (let inb in sb_cfg.inbounds) {
            if (inb.type == "http" || inb.type == "mixed") {
                port = as_string(inb.listen_port || 4534);
                break;
            }
        }
    }
    cached_proxy_port = port;
    return port;
}

function forget_proxy_port() {
    cached_proxy_port = null;
    sb_config_parse_reported = false;
}

function tproxy_port() {
    let port = 4530;
    let sb_cfg = parse_singbox_config();
    if (sb_cfg && sb_cfg.inbounds) {
        for (let inb in sb_cfg.inbounds) {
            if (inb.type == "tproxy") {
                port = int(inb.listen_port || port);
                break;
            }
        }
    }
    return port;
}

// ─── Log line classification ──────────────────────────────────────────────────
// Pure functions: a syslog line in, a fact (or null) out. No I/O, so the
// classifier is directly testable — see tests/event_controller.sh.

// Extract a candidate domain from a sing-box log line. Returns null when the
// line carries no usable hostname. Kept separate from log handling so the
// pattern can be exercised directly by tests.
function smart_detect_extract_domain(line) {
    if (line == null) return null;
    let text = as_string(line);
    let m = match(text, /"([a-zA-Z0-9][a-zA-Z0-9.-]{1,60}\.[a-zA-Z]{2,})(:[0-9]+)?"/);
    if (!m) m = match(text, /target[= ]([a-zA-Z0-9][a-zA-Z0-9.-]{1,60}\.[a-zA-Z]{2,})/);
    if (!m || !m[1]) return null;
    let domain = m[1];
    if (length(domain) < 5) return null;
    if (index(domain, "*") >= 0 || index(domain, "?") >= 0) return null;
    if (index(domain, "..") >= 0) return null;
    if (index(domain, "-") == 0 || substr(domain, length(domain) - 1) == "-") return null;
    return domain;
}

// Classifies one syslog line into zero or more facts, mirroring the branch
// structure of the old handle_log_line() exactly:
//
//   - the keyword pre-filter rejects the overwhelming majority of lines before
//     any lowercasing or regex work happens;
//   - an OOM line is terminal — the original returned right after it, so a line
//     that is both an OOM and a URLTest line yields only the OOM fact;
//   - smart-detect and URLTest are NOT exclusive: the original fell through
//     from one to the other, so both facts can come from a single line. Hence
//     an array return rather than a single fact.
//
// The netlink/nlbwmon discrimination is preserved: misreading a netlink
// warning as OOM would shrink GOMEMLIMIT for nothing.
function classify_log_line(line) {
    if (!line || line == "") return [];

    // Fast keyword pre-filter: skip 95%+ of irrelevant log lines instantly
    if (index(line, "direct") < 0 && index(line, "DIRECT") < 0 &&
        index(line, "memory") < 0 && index(line, "oom") < 0 && index(line, "OOM") < 0 &&
        index(line, "URLTest") < 0 && index(line, "proxy") < 0) {
        return [];
    }

    let line_lower = lc(line);

    let is_oom = (index(line_lower, "oom-killer") >= 0 ||
                  index(line_lower, "out of memory: kill process") >= 0 ||
                  (index(line_lower, "kernel:") >= 0 && index(line_lower, "out of memory") >= 0) ||
                  (index(line_lower, "sing-box") >= 0 && index(line_lower, "out of memory") >= 0) ||
                  index(line_lower, "fatal error: out of memory") >= 0);
    let is_netlink_warning = (index(line_lower, "netlink") >= 0 || index(line_lower, "nlbwmon") >= 0);

    // Terminal, as in the original: no further classification after an OOM.
    if (is_oom && !is_netlink_warning)
        return [ { type: EV.OOM_DETECTED, payload: {} } ];

    let facts = [];

    if ((index(line_lower, "direct") >= 0 || index(line_lower, "DIRECT") >= 0) &&
        (index(line_lower, "failed") >= 0 || index(line_lower, "timeout") >= 0 ||
         index(line_lower, "reset") >= 0)) {
        let domain = smart_detect_extract_domain(line);
        if (domain != null)
            push(facts, { type: EV.SMARTDETECT_CANDIDATE, payload: { domain: domain } });
    }

    if (index(line, "URLTest") >= 0 || index(line_lower, "selected proxy") >= 0 ||
        index(line_lower, "switch proxy") >= 0)
        push(facts, { type: EV.URLTEST_SWITCHED, payload: {} });

    return facts;
}

// ─── Controller ───────────────────────────────────────────────────────────────
// Owns streak counters and latency history: both describe the *observation*,
// not the repair, so they belong on this side of the boundary. Subscribers
// receive the streak in the payload and compare it against their own
// threshold, exactly as the old healers compared their private counters.

function controller(bus, opts) {
    let options = (type(opts) == "object") ? opts : {};
    let log = (type(options.log) == "function") ? options.log : function(msg, lvl) {};

    let state = {
        proxy_consecutive_fails: 0,
        dns_consecutive_fails: 0,
        dns_fail_streak: 0,
        dns_streak_stamp: 0,
        proxy_latency_history: [],
        dns_latency_history: [],
        syslog_start_time: 0,
        logread_pipe_fd: -1,
        last_oom_time: 0,
        healthy_streak: 0
    };

    let self = { EV: EV, state: state };

    // Keeps the last 20 samples. Bounded so a long-lived watchdog cannot grow
    // its heap through the history array.
    function push_history(history, entry) {
        push(history, entry);
        if (length(history) > 20) {
            let trimmed = [];
            for (let i = length(history) - 20; i < length(history); i++)
                push(trimmed, history[i]);
            return trimmed;
        }
        return history;
    }

    // ── Push source: syslog ───────────────────────────────────────────────────
    // Returns the list of facts actually published (after the OOM replay guard,
    // the smart_detect setting and the URLTest throttle), so tests can assert
    // on publication rather than on classification alone.
    self.handle_log_line = function(line) {
        let published = [];

        for (let fact in classify_log_line(line)) {
            if (fact.type == EV.OOM_DETECTED) {
                let now = time();
                // Ignore replay of the historical log buffer that logread -f
                // dumps on start, and collapse an OOM storm into one fact.
                if (state.syslog_start_time > 0 && (now - state.syslog_start_time > 3) &&
                    (now - state.last_oom_time > 60)) {
                    state.last_oom_time = now;
                    bus.emit(EV.OOM_DETECTED, {});
                    push(published, EV.OOM_DETECTED);
                }
                continue;
            }

            if (fact.type == EV.SMARTDETECT_CANDIDATE) {
                if (setting("smart_detect", "0") != "1") continue;
                bus.emit(EV.SMARTDETECT_CANDIDATE, fact.payload);
                push(published, EV.SMARTDETECT_CANDIDATE);
                continue;
            }

            // URLTest switches are chatty; the old check_urltest_switches()
            // throttled itself to one run per 5s, so the fact carries the same.
            if (fact.type == EV.URLTEST_SWITCHED) {
                if (bus.emit_once(EV.URLTEST_SWITCHED, {}, 5) < 0) continue;
                push(published, EV.URLTEST_SWITCHED);
            }
        }

        return published;
    };

    // ── Push source: ubus ─────────────────────────────────────────────────────
    self.handle_ubus_service_stop = function(name, reason) {
        if (as_string(name) != "sing-box") return false;
        bus.emit(EV.SINGBOX_STOPPED, { reason: as_string(reason) });
        return true;
    };

    // handle_ubus_firewall_reload is defined further down, next to the probes it
    // re-runs. Declaration order in this file is load-bearing: ucode captures a
    // closure's upvalues when the closure is created, so a local declared later
    // in the same scope is not captured at all — the name resolves as a global
    // and comes back null. That fails at call time, which neither `ucode -c` nor
    // `ucode -S -c` can see. Every helper here precedes its callers.

    // ── Push source: honeypot FIFO ────────────────────────────────────────────
    self.handle_honeypot_line = function(line) {
        let ip = trim(as_string(line));
        if (ip == "" || match(ip, /^[0-9a-fA-F:.]+$/) == null) return false;
        bus.emit(EV.HONEYPOT_HIT, { ip: ip });
        return true;
    };

    // ── Probe: expired pause ──────────────────────────────────────────────────
    // Declared ahead of probe_singbox, which consults it on every fast tick.
    function probe_pause() {
        let val = trim(fs.readfile("/tmp/tachyon_paused_until") || "");
        if (val == "") return false;
        if (int(val) <= time()) {
            bus.emit(EV.PAUSE_EXPIRED, {});
            return false;
        }
        return true; // still paused
    }
    self.is_paused = probe_pause;

    // ── Probe: sing-box liveness ──────────────────────────────────────────────
    // The expensive /proc scan only runs once the cheap pidfile/ubus/pidof
    // path has already failed, preserving the original fast-path ordering.
    function probe_singbox() {
        if (setting("recovery_bypass", "0") == "1") return;
        // An active pause means sing-box is stopped on purpose. The original
        // check_singbox_process() consulted the pause on every fast tick, so it
        // is consulted here too: leaving it to the normal tier alone would open
        // a window of up to one normal interval in which a deliberate pause is
        // reported as a stop.
        if (probe_pause()) return;
        if (check_tachyon_cli_running()) return;
        if (is_list_update_running()) return;

        let pid = get_sing_box_pid();
        if (pid != "" && process_running(pid, "sing-box")) return;

        // No configured sections means sing-box is legitimately absent.
        let has_sections = false;
        let uci_sections = uci_core.get_all(CONFIG_NAME);
        if (uci_sections) {
            for (let k in keys(uci_sections)) {
                if (uci_sections[k][".type"] == "section") {
                    has_sections = true;
                    break;
                }
            }
        }
        if (!has_sections) return;

        if (sing_box_in_proc() == "")
            bus.emit(EV.SINGBOX_STOPPED, { reason: "process missing from /proc" });
    }

    // ── Probe: proxy reachability ─────────────────────────────────────────────
    // One measurement serves both proxy subscribers (the old
    // ai_heal_proxy_health and ai_heal_proxy_connectivity each ran their own
    // curl). Feature flags are deliberately NOT checked here: the two
    // subscribers are gated by different settings, so the flag belongs to the
    // subscriber. The probe only skips when measuring is pointless or its
    // result would be misleading.
    function probe_proxy() {
        if (!bus.has(EV.PROXY_DOWN) && !bus.has(EV.PROXY_UP)) return;
        // A reload tears the proxy down on purpose; a sample taken now would
        // land in the latency history as a fault that never happened.
        if (is_reload_in_progress()) return;

        let pid = get_sing_box_pid();
        if (pid == "" || !process_running(pid, "sing-box")) return;

        let port = proxy_port();
        let check_url = setting("ai_proxy_health_url", "https://cp.cloudflare.com/generate_204");

        let started = time();
        let ok = command_success_from_args([
            "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
            "--connect-timeout", "3", "--max-time", "5",
            "--proxy", "http://127.0.0.1:" + port,
            check_url
        ]);
        let elapsed = (time() - started) * 1000;

        state.proxy_latency_history = push_history(state.proxy_latency_history,
            { ok: ok, ms: elapsed, ts: time() });

        if (ok) {
            state.proxy_consecutive_fails = 0;
            bus.emit(EV.PROXY_UP, { port: port, ms: elapsed });
            return;
        }

        state.proxy_consecutive_fails++;

        // Distinguish "proxy is broken" from "the whole uplink is down": only
        // the former is worth restarting sing-box over.
        let direct_ok = command_success_from_args([
            "curl", "-s", "-I", "--connect-timeout", "3", "--max-time", "5",
            "https://cp.cloudflare.com/generate_204"
        ]);

        bus.emit(EV.PROXY_DOWN, {
            port: port,
            streak: state.proxy_consecutive_fails,
            direct_ok: direct_ok,
            ms: elapsed
        });
    }

    // Clearing the streak also clears its pacing stamp, so the first failure
    // after a recovery is counted immediately rather than waiting out the rest
    // of an interval that started before the resolver came back.
    function clear_dns_streak() {
        state.dns_fail_streak = 0;
        state.dns_streak_stamp = 0;
    }

    // ── Probe: DNS resolution ─────────────────────────────────────────────────
    // As with the proxy probe, one resolution attempt serves both DNS
    // subscribers; each carries its own enable flag and its own threshold.
    function probe_dns() {
        if (!bus.has(EV.DNS_DOWN) && !bus.has(EV.DNS_UP)) return;
        if (setting("recovery_bypass", "0") == "1") return;

        // A reload restarts the resolver; failures during it are expected and
        // must not accumulate, so the streak resets exactly as before.
        if (is_reload_in_progress()) {
            clear_dns_streak();
            return;
        }

        let pid = get_sing_box_pid();
        if (pid == "" || !process_running(pid, "sing-box")) {
            clear_dns_streak();
            return;
        }

        let started = time();
        let ok = is_dns_working();
        let elapsed = (time() - started) * 1000;

        state.dns_latency_history = push_history(state.dns_latency_history,
            { ok: ok, ms: elapsed, ts: time() });

        if (ok) {
            state.dns_consecutive_fails = 0;
            clear_dns_streak();
            bus.emit(EV.DNS_UP, { ms: elapsed });
            return;
        }

        state.dns_consecutive_fails++;

        // Two counters at two rates, because the two DNS healers were measured on
        // two different tiers before the split: dns_consecutive_fails came from
        // the fast tier (15s), dns_fail_streak from the normal-tier audit (120s+).
        // The probe now runs once at the fast rate, so the streak is only stepped
        // once per DNS_STREAK_INTERVAL to keep "3 failures" meaning the same
        // ~6 minutes of trouble it meant before, not 45 seconds.
        let now = time();
        if (now - state.dns_streak_stamp >= DNS_STREAK_INTERVAL) {
            state.dns_streak_stamp = now;
            state.dns_fail_streak++;
            log("Watchdog: DNS check failed (" + as_string(state.dns_fail_streak) + "/3 failures)", "warn");
        }

        bus.emit(EV.DNS_DOWN, {
            streak: state.dns_fail_streak,
            consecutive: state.dns_consecutive_fails,
            ms: elapsed
        });
    }

    // ── Probe: memory ─────────────────────────────────────────────────────────
    function read_mem_available_mb() {
        let mem_info = fs.readfile("/proc/meminfo") || "";
        for (let line in split(mem_info, "\n")) {
            if (index(line, "MemAvailable:") == 0) {
                let fields = split(trim(line), /[ \t]+/);
                if (length(fields) >= 2)
                    return int(fields[1]) / 1024;
                break;
            }
        }
        return -1;
    }
    self.read_mem_available_mb = read_mem_available_mb;

    function probe_memory() {
        let free_mb = read_mem_available_mb();
        if (free_mb >= 0 && free_mb < 15)
            bus.emit(EV.MEMORY_LOW, { free_mb: free_mb });
    }

    // ── Probe: nftables table and QoS marks ───────────────────────────────────
    function probe_nftables() {
        if (is_list_update_running()) return;
        if (is_reload_in_progress()) return;

        let nft_table = getenv("NFT_TABLE_NAME") || "TachyonTable";
        let routing_mode = setting("routing_mode", "nftables");
        let out_nft = command_output_from_args(["sh", "-c",
            "nft list table inet " + nft_table + " | grep -E 'chain|tproxy|priority_rules|dscp'; exit 0"]);

        if (routing_mode == "nftables") {
            if (index(out_nft, "tproxy") < 0 || index(out_nft, "priority_rules") < 0) {
                bus.emit(EV.NFT_MISSING, { table: nft_table });
                return;
            }
        }

        if (setting("qos_priority_engine", "1") == "0") return;
        if ((index(out_nft, "dscp set 0x2e") < 0 && index(out_nft, "dscp set ef") < 0) ||
            (index(out_nft, "dscp set 0x22") < 0 && index(out_nft, "dscp set af41") < 0))
            bus.emit(EV.QOS_MISSING, { table: nft_table });
    }

    // ── Probe: TPROXY port liveness ───────────────────────────────────────────
    function probe_tproxy() {
        if (setting("recovery_bypass", "0") == "1") return;
        if (is_reload_in_progress()) return;

        let pid = get_sing_box_pid();
        if (pid == "" || !process_running(pid, "sing-box")) return;

        let port = tproxy_port();
        // /proc/net/tcp encodes the local port in hex; 0A is TCP_LISTEN.
        let hex_port = sprintf("%04X", port);
        let listening = false;
        for (let proc_file in ["/proc/net/tcp6", "/proc/net/tcp"]) {
            let tcp_data = fs.readfile(proc_file) || "";
            for (let line in split(tcp_data, "\n")) {
                if (index(line, ":" + hex_port + " ") >= 0 && index(line, " 0A ") >= 0) {
                    listening = true;
                    break;
                }
            }
            if (listening) break;
        }

        if (!listening)
            bus.emit(EV.TPROXY_DOWN, { port: port });
    }

    // ── Probe: rpcd file descriptor leak ──────────────────────────────────────
    // rpcd accumulates FDs from LuCI API calls. Past ~1024 it can no longer
    // fork /usr/bin/tachyon and LuCI reports everything as stopped. 512 is
    // half the limit — early enough to restart without user-visible impact.
    const RPCD_FD_THRESHOLD = 512;

    function probe_rpcd() {
        let rpcd_pid = null;
        let proc_dir = fs.opendir("/proc");
        if (!proc_dir) return;
        let entry;
        while ((entry = proc_dir.read()) != null) {
            if (!match(entry, /^[0-9]+$/)) continue;
            let comm = trim(fs.readfile("/proc/" + entry + "/comm") || "");
            if (comm == "rpcd") { rpcd_pid = entry; break; }
        }
        proc_dir.close();
        if (!rpcd_pid) return;

        let fd_dir = fs.opendir("/proc/" + rpcd_pid + "/fd");
        if (!fd_dir) return;
        let fd_count = 0;
        while ((entry = fd_dir.read()) != null) {
            if (match(entry, /^[0-9]+$/)) fd_count++;
        }
        fd_dir.close();

        if (fd_count > RPCD_FD_THRESHOLD)
            bus.emit(EV.RPCD_FD_LEAK, { fd_count: fd_count, threshold: RPCD_FD_THRESHOLD });
    }

    // ── Probe: WAN address and default route ──────────────────────────────────
    function probe_wan() {
        if (is_reload_in_progress()) return;

        let proto = uci_core.get("network", "wan", "proto") || "pppoe";
        let device = trim(uci_core.get("network", "wan", "device") || "eth0");
        let iface = (proto == "pppoe") ? "pppoe-wan" : device;

        let addr_out = command_capture("ip addr show " + shell_quote(iface) + " 2>/dev/null").output;
        let no_address = index(addr_out, "inet ") < 0;

        let route_out = command_capture("ip route 2>/dev/null").output;
        let no_gateway = index(route_out, "default") < 0;

        if (no_address || no_gateway)
            bus.emit(EV.WAN_DOWN, { iface: iface, no_address: no_address, no_gateway: no_gateway });
        else
            bus.emit(EV.WAN_UP, { iface: iface });
    }

    // ── Probe: community subnet nft sets ──────────────────────────────────────
    function probe_subnet_sets() {
        if (setting("recovery_bypass", "0") == "1") return;
        if (is_reload_in_progress()) return;
        if (is_list_update_running()) return;

        let pid = get_sing_box_pid();
        if (pid == "" || !process_running(pid, "sing-box")) return;

        let nft_table = getenv("NFT_TABLE_NAME") || "TachyonTable";
        let all_sections = uci_core.get_all(CONFIG_NAME);
        if (!all_sections) return;

        let empty = [];
        for (let sec_name in keys(all_sections)) {
            let s = all_sections[sec_name];
            if (s[".type"] != "section" || s.enabled != "1") continue;
            if (!s.community_lists) continue;

            // A non-zero exit means the set does not exist for this section
            // (no subnet community configured) — not an emptiness problem.
            let set_name = "tachyon_rule_" + sec_name + "_subnets";
            let result = command_capture(
                command_from_args(["nft", "list", "set", "inet", nft_table, set_name]) + " 2>/dev/null");
            if (result.status != 0 || result.output == "") continue;
            if (index(result.output, "elements") < 0)
                push(empty, set_name);
        }

        if (length(empty) > 0)
            bus.emit(EV.SUBNETS_EMPTY, { sets: empty });
    }

    // ── Probe: subscription URL reachability ──────────────────────────────────
    function probe_subscription() {
        let sub_url = trim(setting("subscription_url", ""));
        if (sub_url == "") return;

        let res = command_capture(
            "curl -s -o /dev/null -w %{http_code} --connect-timeout 10 " + shell_quote(sub_url) + " 2>&1");
        let code = int(res.output);
        if (res.status == 0 && code >= 200 && code < 400) return;

        bus.emit(EV.SUBSCRIPTION_UNREACHABLE, { url: sub_url, code: code });
    }

    // ── Probe: UCI config integrity ───────────────────────────────────────────
    function probe_config() {
        let data = fs.readfile("/etc/config/tachyon");
        if (data == null || data == "")
            bus.emit(EV.CONFIG_CORRUPT, {});
    }

    // ── Probe: proxy sections with subscriptions but no usable outbounds ──────
    function probe_empty_sections() {
        if (!enabled("ai_section_failover_enabled", "1")) return;
        if (is_reload_in_progress()) return;

        let connections = require("config.connections");
        let sections = common.object_or_empty(uci_core.get_all(CONFIG_NAME));
        let empty = [];

        for (let name in sections) {
            let s = common.object_or_empty(sections[name]);
            let action = common.as_string(s.action || "");
            if (!connections.is_connections_action(action)) continue;
            let sub_urls = common.list_option(s, "subscription_url");
            if (length(sub_urls) == 0) continue;

            let cache = common.object_or_empty(
                common.read_json_file("/var/run/tachyon/section-cache/" + name + ".json"));
            let usable = length(common.array_or_empty(cache.servers)) +
                         length(common.array_or_empty(cache.urls)) +
                         length(common.array_or_empty(cache.selector_urls)) +
                         length(common.array_or_empty(cache.domain)) +
                         length(common.array_or_empty(cache.domain_suffix)) +
                         length(common.array_or_empty(cache.ip_cidr));
            if (usable > 0) continue;

            push(empty, name);
        }

        if (length(empty) > 0)
            bus.emit(EV.SECTIONS_EMPTY, { sections: empty });
    }

    // ── Probe: reconnect rate anomaly ─────────────────────────────────────────
    function probe_anomalies() {
        if (!enabled("ai_anomaly_detection_enabled", "1")) return;

        let threshold = int(setting("ai_anomaly_reconnect_threshold", "10"));
        let reconnects = int(trim(fs.readfile("/tmp/tachyon_reconnect_count") || "0"));

        if (reconnects > threshold)
            bus.emit(EV.ANOMALY_RECONNECTS, { count: reconnects, threshold: threshold });
    }

    // ── Probe: OOM scale recovery window ──────────────────────────────────────
    // Half an hour without an OOM means the shrunk GOMEMLIMIT can start
    // creeping back up; the healer decides by how much.
    // A scale of 1.0 means there is nothing to restore, so the marker file is
    // dropped here rather than published as a fact: removing a stale file is an
    // observation cleanup, not a repair a subscriber should have to schedule.
    function probe_oom_recovery() {
        let now = time();
        if (state.last_oom_time == 0) return;
        if (now - state.last_oom_time < 1800) return;

        let scale_path = "/etc/tachyon/mem_scale";
        let scale_data = fs.readfile(scale_path);
        if (scale_data == null) return;
        let current_scale = double(trim(as_string(scale_data)));
        if (current_scale >= 1.0) {
            // Absent file already satisfies the caller; fs.unlink throws on ENOENT.
            try { fs.unlink(scale_path); } catch (e) {}
            return;
        }
        if (current_scale < 0.1) return;

        bus.emit(EV.OOM_RECOVERABLE, { last_oom: state.last_oom_time, scale: current_scale });
    }

    // ── Tier drivers ──────────────────────────────────────────────────────────
    // Each probe is wrapped so one failing observation cannot stop the tier;
    // this mirrors the safe_call() isolation the old per-check loop had.
    function run_probe(fn, name) {
        try {
            fn();
        }
        catch (e) {
            log("Probe " + name + " failed: " + as_string(e), "err");
        }
    }

    // ── Push source: ubus firewall.reload ─────────────────────────────────────
    // Declared here, after run_probe and the two probes it drives, because a
    // closure cannot capture a local declared below it (see the note above
    // handle_honeypot_line). A firewall reload can wipe our table and flush the
    // community sets, so those two probes re-run immediately instead of waiting
    // for the next tier tick — this is what check_firewall_rules() did on this
    // event.
    self.handle_ubus_firewall_reload = function() {
        bus.emit(EV.FIREWALL_RELOADED, {});
        run_probe(probe_nftables, "nftables");
        run_probe(probe_subnet_sets, "subnet_sets");
        return true;
    };

    self.probe_fast = function() {
        run_probe(probe_singbox, "singbox");
        run_probe(probe_proxy, "proxy");
        run_probe(probe_dns, "dns");    };

    self.probe_normal = function() {
        run_probe(probe_pause, "pause");
        run_probe(probe_memory, "memory");
        run_probe(probe_rpcd, "rpcd");
        run_probe(probe_nftables, "nftables");
        run_probe(probe_tproxy, "tproxy");
    };

    self.probe_slow = function() {
        run_probe(probe_subnet_sets, "subnet_sets");
        run_probe(probe_wan, "wan");
        run_probe(probe_subscription, "subscription");
        run_probe(probe_config, "config");
        run_probe(probe_empty_sections, "empty_sections");
        run_probe(probe_anomalies, "anomalies");
        run_probe(probe_oom_recovery, "oom_recovery");
    };

    // Health is graded by how long we go without publishing a fault: after a
    // long clean streak the normal tier can afford to slow down.
    self.adaptive_normal_interval = function() {
        if (!enabled("ai_adaptive_intervals_enabled", "1")) return 120;
        return state.healthy_streak > 25 ? 300 : 120;
    };

    self.note_healthy = function() { state.healthy_streak++; };
    self.note_incident = function() { state.healthy_streak = 0; };
    self.note_oom = function(ts) { state.last_oom_time = ts != null ? int(ts) : time(); };
    self.set_syslog_start = function(ts) { state.syslog_start_time = int(ts); };

    // Streak resets belong to whoever acted on the fact: the old healers zeroed
    // their counter right after restarting, so that a restart-in-flight would
    // not immediately trip the same threshold again on the next tick.
    self.reset_dns_streak = clear_dns_streak;
    self.reset_dns_consecutive = function() { state.dns_consecutive_fails = 0; };
    self.reset_proxy_consecutive = function() { state.proxy_consecutive_fails = 0; };

    // Latency history and streak counters feed ai-status-full and the metrics
    // export, which are still owned by the watchdog.
    self.proxy_latency_history = function() { return state.proxy_latency_history; };
    self.dns_latency_history = function() { return state.dns_latency_history; };
    self.proxy_consecutive_fails = function() { return state.proxy_consecutive_fails; };
    self.dns_consecutive_fails = function() { return state.dns_consecutive_fails; };
    self.healthy_streak = function() { return state.healthy_streak; };

    self.forget_proxy_port = forget_proxy_port;
    self.get_sing_box_pid = get_sing_box_pid;
    self.is_dns_working = is_dns_working;
    self.is_reload_in_progress = is_reload_in_progress;
    self.is_list_update_running = is_list_update_running;
    self.check_tachyon_cli_running = check_tachyon_cli_running;
    self.proxy_port = proxy_port;

    return self;
}

function module_exports() {
    return {
        controller,
        classify_log_line,
        smart_detect_extract_domain,
        EV
    };
}

if (sourcepath(1) != null && sourcepath(1) != "")
    return module_exports();

// CLI surface for the shell test suite, which cannot import a ucode module.
let mode = ARGV[0] || "";

if (mode == "classify") {
    let facts = classify_log_line(ARGV[1]);
    if (length(facts) == 0) exit(1);
    // One type per line, in publication order.
    for (let fact in facts)
        print(fact.type + "\n");
    exit(0);
}
else if (mode == "classify-domain") {
    for (let fact in classify_log_line(ARGV[1])) {
        if (fact.payload.domain != null) {
            print(fact.payload.domain + "\n");
            exit(0);
        }
    }
    exit(1);
}
else if (mode == "extract-domain") {
    let extracted = smart_detect_extract_domain(ARGV[1]);
    if (extracted == null) exit(1);
    print(extracted + "\n");
    exit(0);
}
else if (mode == "event-types") {
    for (let k in sort(keys(EV)))
        print(k + "=" + EV[k] + "\n");
    exit(0);
}
else {
    warn("Usage: service/event_controller.uc <classify|classify-domain|extract-domain|event-types> ...\n");
    exit(1);
}
