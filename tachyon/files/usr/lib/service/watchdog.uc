#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");
let common = require("core.common");
let helpers = require("core.helpers");
let connections = require("config.connections");
let events = require("core.events");
let event_controller = require("service.event_controller");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const PID_FILE = "/var/run/tachyon_watchdog.pid";
const WATCHDOG_UC = LIB_DIR + "/service/watchdog.uc";
const PAUSE_FILE = "/tmp/tachyon_paused_until";
const SMART_DETECT_SEEN_FILE = "/etc/tachyon/smart_detect_seen.json";


let as_string = common.as_string;
let shell_quote = common.shell_quote;

let proxy_restart_count = 0;
let proxy_restart_window_start = time();
const PROXY_RESTART_LOCK = "/var/run/tachyon_proxy_restart.lock";
let telegram_msg_count = 0;
let telegram_msg_window = time();
// FD-cascade prevention: track logread pipe FD to close it in background spawns
let logread_pipe_fd = -1;

let command_from_args = common.command_from_args;
let command_status = common.command_status;
let command_success_from_args = common.command_success_from_args;
let is_process_name_running = helpers.is_process_name_running;

function command_capture(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return { status: 1, output: "" };
    let data = pipe.read("all");
    let status = pipe.close();
    if (status > 255) status = int(status / 256);
    return { status, output: data == null ? "" : as_string(data) };
}

// Run a command in background, explicitly closing the logread pipe FD to
// prevent FD-cascade: each restart/reload inherits read-end of logread pipe,
// keeping orphaned logread -f processes alive across watchdog generations.
function bg_system(cmd) {
    if (logread_pipe_fd >= 0) {
        system(sprintf("%d<&- ", logread_pipe_fd) + cmd);
    } else {
        system(cmd);
    }
}

function settings() {
    return common.object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
}

function remove_file(path) {
    try {
        fs.unlink(as_string(path));
    }
    catch (e) {
    }
}

function log_message(message, level) {
    let priority = 6;
    let lvl = as_string(level || "info");
    if (lvl == "warn" || lvl == "warning") {
        priority = 4;
    } else if (lvl == "err" || lvl == "error" || lvl == "fatal") {
        priority = 3;
    } else if (lvl == "debug") {
        priority = 7;
    }
    
    let kmsg = fs.open("/dev/kmsg", "w");
    if (kmsg) {
        kmsg.write(sprintf("<%d>tachyon: [%s] Watchdog: %s\n", priority, lvl, as_string(message)));
        kmsg.close();
    } else {
        command_success_from_args([ "logger", "-t", "tachyon", "[" + lvl + "] Watchdog: " + as_string(message) ]);
    }
}

function send_telegram_notification(message) {
    let now = time();
    if (now - telegram_msg_window > 300) {
        telegram_msg_count = 0;
        telegram_msg_window = now;
    }
    if (telegram_msg_count >= 10) return;
    telegram_msg_count++;
    let tcfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
    if (tcfg.enabled == "1" && tcfg.bot_token && tcfg.admin_ids) {
        system("/usr/bin/tachyon telegram send " + shell_quote(message) + " </dev/null >/dev/null 2>&1 1000<&- &");
    }
}

function process_running(pid, expected_name) {
    if (match(as_string(pid), /^[0-9]+$/) == null)
        return false;
    if (expected_name != null && expected_name != "") {
        return is_process_name_running(pid, expected_name);
    }
    return fs.stat("/proc/" + pid) != null;
}

function stop_runtime() {
    let pid = trim(fs.readfile(PID_FILE) || "");
    if (process_running(pid, "ucode")) {
        command_success_from_args([ "kill", pid ]);
        let wait_limit = 50; // 5 seconds
        while (wait_limit > 0 && process_running(pid, "ucode")) {
            sleep(100);
            wait_limit--;
        }
        if (process_running(pid, "ucode")) {
            command_success_from_args([ "kill", "-9", pid ]);
        }
    }
    remove_file(PID_FILE);

    // Stop Honeypot listener
    let hp_pid = trim(fs.readfile("/var/run/tachyon_honeypot_listener.pid") || "");
    if (process_running(hp_pid)) {
        command_success_from_args([ "kill", hp_pid ]);
        let wait_limit = 20; // 2 seconds
        while (wait_limit > 0 && process_running(hp_pid)) {
            sleep(100);
            wait_limit--;
        }
        if (process_running(hp_pid)) {
            command_success_from_args([ "kill", "-9", hp_pid ]);
        }
    }
    remove_file("/var/run/tachyon_honeypot_listener.pid");
    remove_file("/tmp/tachyon_honeypot.fifo");
    remove_file(PROXY_RESTART_LOCK);

    return 0;
}

// ─── Pause auto-resume ────────────────────────────────────────────────────────
function check_auto_resume_pause() {
    let val = trim(fs.readfile(PAUSE_FILE) || "");
    if (val == "") return false;
    let until = int(val);
    let now = time();
    if (until <= now) {
        remove_file(PAUSE_FILE);
        log_message("Pause expired, auto-resuming Tachyon...", "info");
        command_status("/usr/bin/tachyon start > /dev/null 2>&1");
        let tcfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
        if (tcfg.enabled == "1" && tcfg.bot_token && tcfg.admin_ids) {
            send_telegram_notification("▶️ Прокси возобновлён (пауза истекла).");
        }
        return false;
    }
    return true; // still paused, skip normal checks
}

// ─── Smart Detect — self-healing routing ─────────────────────────────────────
function smart_detect_get_proxy_sections() {
    let c = uci_core.cursor();
    if (!c) return [];
    c.load(CONFIG_NAME);
    let connections = require("config.connections");
    let secs = [];
    c.foreach(CONFIG_NAME, "section", function(s) {
        if (s.enabled != "1") return;
        let act = as_string(s.action || "");
        if (act != "bypass" && act != "block" && act != "dns" && act != "") {
            push(secs, s[".name"]);
        }
    });
    return secs;
}

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

// A domain that resolves nowhere is a DNS fault, not a block: probing it would
// fail directly and via proxy alike, so treat it as unresolvable and skip.
function smart_detect_domain_resolves(domain) {
    return command_success_from_args([ "nslookup", domain, "127.0.0.1" ]) ||
           command_success_from_args([ "nslookup", domain ]);
}

function smart_detect_add_domain(sec_name, domain) {
    let c = uci_core.cursor();
    if (!c) return false;
    c.load(CONFIG_NAME);
    let sec = c.get_all(CONFIG_NAME, sec_name);
    if (!sec) return false;
    let existing = sec.user_domains;
    if (type(existing) != "array") {
        existing = (existing && trim(as_string(existing)) != "") ? [trim(as_string(existing))] : [];
    }
    for (let d in existing) {
        if (trim(as_string(d)) == domain) return true;
    }
    c.list_add(CONFIG_NAME, sec_name, "user_domains", domain);
    c.commit(CONFIG_NAME);
    command_status("/usr/bin/tachyon reload > /dev/null 2>&1");
    return true;
}




function start_runtime() {
    let cfg = settings();
    stop_runtime();

    let enable_watchdog = cfg.enable_watchdog != "0";
    if (!enable_watchdog) {
        return 0;
    }

    let command = command_from_args([ "ucode", "-L", LIB_DIR, WATCHDOG_UC, "worker" ]) +
        " </dev/null >/dev/null 2>&1 1000<&- & echo $! >" + shell_quote(PID_FILE);
    return command_status(command);
}

function run_zero_rtt_prefetching() {
    let cfg = settings();
    let sections = uci_core.get_all(CONFIG_NAME);
    if (!sections) return;

    let unique_domains = {};
    for (let k in keys(sections)) {
        let sec = sections[k];
        if (sec.enabled == "0") continue;

        let list_val = sec.user_domains;
        let list_array = [];
        if (type(list_val) == "array") {
            list_array = list_val;
        } else if (list_val) {
            list_array = split(trim(as_string(list_val)), /\s+/);
        }

        for (let dom in list_array) {
            dom = trim(dom);
            if (dom != "" && index(dom, "*") < 0 && index(dom, "?") < 0) {
                unique_domains[dom] = true;
            }
        }

        let text_val = sec.user_domains_text;
        if (text_val) {
            for (let line in split(text_val, "\n")) {
                line = trim(line);
                if (line != "" && index(line, "#") != 0 && index(line, "*") < 0 && index(line, "?") < 0) {
                    unique_domains[line] = true;
                }
            }
        }
    }

    let domain_list = keys(unique_domains);
    if (length(domain_list) == 0) return;

    log_message("Zero-RTT Prefetcher: pre-resolving " + length(domain_list) + " domains in batches...", "info");
    let batch = [];
    for (let i, dom in domain_list) {
        push(batch, shell_quote(dom));
        if (length(batch) >= 15 || i == length(domain_list) - 1) {
            let batch_cmd = "for d in " + join(" ", batch) + "; do dig @127.0.0.1 \"$d\" A >/dev/null 2>&1; done &";
            system(batch_cmd + " </dev/null >/dev/null 2>&1 1000<&-");
            batch = [];
        }
    }
}

let uloop = null;
let ubus = null;
try { uloop = require("uloop"); } catch (e) {}
try { ubus = require("ubus"); } catch (e) {}

// ─── Event bus and observation controller ─────────────────────────────────────
// The controller observes and publishes facts; everything below subscribes and
// repairs. Splitting the two is what removes the detection prologue that used
// to be copy-pasted into the head of every ai_heal_* function.
let EV = event_controller.EV;
let bus = events.bus();
let controller = event_controller.controller(bus, {
    log: function(message, level) { log_message(message, level); }
});

// A subscriber that throws must not silence the subscribers behind it. This is
// the isolation safe_call() gave each check in the old loop, now applied once
// by the bus to every handler.
bus.on_error(function(name, event_type, err) {
    log_message("Graceful degradation: " + name + " (" + event_type + ") failed: " + as_string(err), "err");
});

// Repair-side pacing. Unlike the observation counters below, these belong to
// the action: they debounce how often a healer is allowed to act, not how often
// the world is measured.
let last_oom_recovery_time = 0;
let last_restart_time = 0;
let last_reload_time = 0;
let pending_smart_domains = {};
let smart_detect_last_run = 0;
let last_fast_check = 0;
let last_normal_check = 0;
let last_slow_check = 0;

// Observation state lives in the controller; these read through to it so the
// status and metrics contracts keep reporting exactly the same numbers.
function proxy_consecutive_fails() { return controller.proxy_consecutive_fails(); }
function dns_consecutive_fails() { return controller.dns_consecutive_fails(); }
function proxy_latency_history() { return controller.proxy_latency_history(); }
function dns_latency_history() { return controller.dns_latency_history(); }

function check_tachyon_cli_running() {
    let running = false;
    let proc = fs.opendir("/proc");
    if (proc) {
        let entry;
        while ((entry = proc.read()) != null) {
            if (match(entry, /^[0-9]+$/)) {
                let cmdline = fs.readfile("/proc/" + entry + "/cmdline") || "";
                if (index(cmdline, "/usr/bin/tachyon") >= 0) {
                    if (index(cmdline, "start") >= 0 || index(cmdline, "restart") >= 0 || index(cmdline, "reload") >= 0 || index(cmdline, "stop") >= 0) {
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

// ─── Recovery watch: registration ─────────────────────────────────────────────
// A repair that goes through safe_proxy_restart() is spawned into the
// background, so its return value says only that the restart was launched. The
// only honest evidence that it worked is the system recovering afterwards —
// which the controller already publishes as PROXY_UP / DNS_UP.
//
// A healer therefore registers what it expects to see. settle_recovery(), below
// ai_heal_report(), turns the arrival of that fact into a `fixed` report and a
// watch left open past its deadline into a `failed` one.
let recovery_watches = {};

// Two fast ticks plus margin: long enough for a restarted sing-box to answer,
// short enough that a failure is reported while it is still actionable.
const RECOVERY_DEADLINE = 45;

function watch_recovery(key, recovery_event, incident) {
    recovery_watches[key] = {
        event: recovery_event,
        incident: incident,
        deadline: time() + RECOVERY_DEADLINE
    };
}

// The 30s floor is the original restart debounce: procd emits several stop
// events for one crash, and each would otherwise queue its own restart.
function heal_singbox_stopped(ev) {
    let now = time();
    if (now - last_restart_time < 30) return;
    last_restart_time = now;

    let cfg = settings();
    if (cfg.recovery_bypass == "1") return;
    if (check_auto_resume_pause()) return;
    if (check_tachyon_cli_running()) return;

    let list_update_pid = trim(fs.readfile("/var/run/tachyon_list_update.pid") || "");
    if (process_running(list_update_pid, "ucode")) return;

    log_message("sing-box is stopped (" + as_string(ev.payload.reason || "health check") + "). Restarting Tachyon...", "warn");
    increment_reconnect_count();
    let tcfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
    if (tcfg.notify_crash != "0") {
        send_telegram_notification("⚠️ *Watchdog:* sing-box остановлен. Перезапускаю службы Tachyon...");
    }
    // This healer sends its own notification above and deliberately did not file
    // an incident, so it does not start one now. It does register the watch: a
    // restart that never brings the proxy back is worth a `failed` report, and
    // that report is the only thing here that is new.
    if (safe_proxy_restart("singbox_stopped")) {
        watch_recovery("proxy", EV.PROXY_UP, {
            type: "singbox_stopped",
            description: "sing-box остановлен (" + as_string(ev.payload.reason || "health check") + ")",
            resolution: "Выполнен перезапуск служб Tachyon"
        });
    }
}

function get_sing_box_pid() {
    return controller.get_sing_box_pid();
}

// ─── AI Watchdog Self-Healing Matrix ──────────────────────────────────────────
let ai_incidents_count = 0;
let last_ai_incident = null;

function ai_export_status() {
    let is_healthy = last_ai_incident == null || (time() - last_ai_incident.timestamp >= 300);
    if (is_healthy) controller.note_healthy();
    let status_obj = {
        timestamp: time(),
        status: is_healthy ? "healthy" : "repaired",
        ai_active: true,
        incidents_resolved_total: ai_incidents_count,
        last_incident: last_ai_incident
    };
    fs.writefile("/tmp/tachyon_ai_status.json", sprintf("%J\n", status_obj));
}

// `outcome` is what actually happened, not what was attempted:
//
//   fixed    the repair ran and the fault is gone
//   pending  the repair ran; the system has not recovered yet
//   failed   the repair ran and the fault outlived the deadline
//   skipped  the repair did not run (rate limit, lock, guard)
//   warn     an observation reported for the record, with no repair
//
// Repairs whose effect is asynchronous (anything going through
// safe_proxy_restart) cannot know their outcome at call time, so they report
// `pending` and let the recovery watch below settle it.
function ai_heal_report(event_type, description, resolution, outcome) {
    let status_code = as_string(outcome || "fixed");

    ai_incidents_count++;
    controller.note_incident();
    last_ai_incident = {
        type: event_type,
        description: description,
        resolution: resolution,
        outcome: status_code,
        timestamp: time()
    };

    let log_msg = sprintf("🤖 [AI Watchdog] %s. Action taken: %s [%s]",
        description, resolution, status_code);
    log_message(log_msg, status_code == "failed" ? "err" : "warn");

    // A repair still in flight is not news: notifying on `pending` would send
    // one message on the attempt and a second on the outcome. The settled
    // report carries the whole story, so only that one is sent.
    let tcfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
    if (status_code != "pending" &&
        tcfg.enabled == "1" && tcfg.bot_token && tcfg.admin_ids && tcfg.notify_crash != "0") {
        let icon = status_code == "failed" ? "❌" : "🔧";
        let verdict = status_code == "failed" ? "*Не помогло:*" :
                      (status_code == "skipped" ? "*Пропущено:*" : "*Авто-решение:*");
        let tg_msg = sprintf("🤖 *[ИИ-Автомеханик Tachyon]*\n⚠️ *Проблема:* %s\n%s %s %s",
            description, icon, verdict, resolution);
        send_telegram_notification(tg_msg);
    }

    ai_export_status();
}

// ─── Recovery watch: settling ─────────────────────────────────────────────────
// The registration half lives above heal_singbox_stopped, its first caller.
// Settling has to live here instead, below ai_heal_report — ucode captures a
// closure's upvalues at creation, so a function declared above ai_heal_report
// could not call it.
//
// Settling reports the outcome the caller observed, reusing the description and
// resolution the healer already wrote so the two reports read as one story.
function settle_recovery(key, outcome) {
    let watch = recovery_watches[key];
    if (watch == null) return false;
    delete recovery_watches[key];

    let incident = watch.incident;
    ai_heal_report(incident.type, incident.description, incident.resolution, outcome);
    return true;
}

function settle_expired_recoveries() {
    let now = time();
    for (let key in keys(recovery_watches)) {
        if (recovery_watches[key].deadline <= now)
            settle_recovery(key, "failed");
    }
}

// Recovery facts are already published by the probes; these subscribers are the
// only thing that was missing.
function note_proxy_recovered(ev) {
    settle_recovery("proxy", "fixed");
}

function note_dns_recovered(ev) {
    settle_recovery("dns", "fixed");
}

// Guard: skip if a tachyon reload is already in progress (prevents concurrent reload_firewall races)
function is_reload_in_progress() {
    return fs.stat("/var/run/tachyon.reload.lock") != null
        || check_tachyon_cli_running();
}

function safe_proxy_restart(reason) {
    let now = time();
    if (now - proxy_restart_window_start > 600) {
        proxy_restart_count = 0;
        proxy_restart_window_start = now;
    }
    if (proxy_restart_count >= 3) {
        log_message("Proxy restart rate limit: " + as_string(proxy_restart_count) + " in 10 min, skipping (" + reason + ")", "warn");
        return false;
    }
    if (fs.stat(PROXY_RESTART_LOCK) != null) {
        let lock_content = trim(fs.readfile(PROXY_RESTART_LOCK) || "0");
        let lock_age = now - int(lock_content);
        if (lock_age < 300) {
            log_message("Proxy restart lock exists (age " + as_string(lock_age) + "s), skipping (" + reason + ")", "warn");
            return false;
        }
        log_message("Proxy restart lock stale (age " + as_string(lock_age) + "s), removing", "warn");
        remove_file(PROXY_RESTART_LOCK);
    }
    try { fs.writefile(PROXY_RESTART_LOCK, as_string(now)); } catch(e) {}
    proxy_restart_count++;
    // The proxy port can change across a restart, so the controller's cached
    // lookup is invalidated here rather than after the fact.
    controller.forget_proxy_port();
    let lock_path = shell_quote(PROXY_RESTART_LOCK);
    bg_system("/etc/init.d/tachyon restart </dev/null >/dev/null 2>&1 & rm -f " + lock_path + " &");
    return true;
}

// ─── Reload dedup: prevent multiple reload_firewall per cycle ─────────────────
function safe_reload_firewall() {
    let now = time();
    let min_interval = 120;
    if (now - last_reload_time < min_interval) return;
    last_reload_time = now;
    bg_system("/usr/bin/tachyon reload_firewall </dev/null >/dev/null 2>&1 &");
}

// ─── Repairs ──────────────────────────────────────────────────────────────────
// Each function below is the *action* half of a former ai_heal_* function: the
// detection it used to perform now happens in the controller and arrives as a
// fact. The repair bodies themselves are unchanged, so thresholds, messages and
// side effects stay identical.

function heal_nftables(ev) {
    ai_heal_report(
        "nftables",
        "Таблица правил nftables очищена или повреждена",
        "Выполнена быстрая регенерация правил TachyonTable и цепочки TPROXY",
        "fixed"
    );
    safe_reload_firewall();
}

function heal_qos(ev) {
    ai_heal_report(
        "qos_priority",
        "Правила Игрового & Голосового QoS Ускорителя не найдены в nftables",
        "Применены высокоприоритетные метки DSCP EF (0x2e) для Voice/RTC и DSCP AF41 (0x22) для Gaming",
        "fixed"
    );
    safe_reload_firewall();
}

function is_dns_working() {
    return controller.is_dns_working();
}

// Threshold 3 is the original ai_heal_dns() streak: two isolated failures are
// noise, three in a row is a stall. The streak reset after acting prevents the
// in-flight restart from tripping the same threshold on the next tick.
function heal_dns_stall(ev) {
    if (settings().recovery_bypass == "1") return;
    if (int(ev.payload.streak) < 3) return;

    controller.reset_dns_streak();

    log_message("Watchdog: DNS stalled after 3 attempts, soft-reloading proxy runtime", "warn");

    let incident = {
        type: "dns",
        description: "DNS resolution stalled on sing-box (port 53)",
        resolution: "Soft-reloaded proxy runtime safely without breaking active TCP/RDP connections"
    };

    // The restart is asynchronous, so `true` means only that it was launched.
    // The watch on DNS_UP decides whether it worked.
    if (!safe_proxy_restart("dns_stalled")) {
        ai_heal_report(incident.type, incident.description,
            "Перезапуск не выполнен: лимит частоты или активная блокировка", "skipped");
        return;
    }
    watch_recovery("dns", EV.DNS_UP, incident);
}

// Only a proxy that fails while the uplink itself works is worth restarting
// over: when direct access is down too, the fault is upstream and a restart
// would drop live connections for nothing.
function heal_proxy_connectivity(ev) {
    if (settings().recovery_bypass == "1") return;
    if (!ev.payload.direct_ok) return;

    let proxy_addr = "127.0.0.1:" + as_string(ev.payload.port);
    let incident = {
        type: "proxy",
        description: "Зависание или неполный отклик прокси-порту sing-box (" + proxy_addr + ")",
        resolution: "Очищена база cache.db и выполнен перезапуск sing-box"
    };

    remove_file("/tmp/sing-box/cache.db");
    // Reporting used to happen here, before the restart, so a rate-limited
    // attempt still announced a repair that never ran.
    if (!safe_proxy_restart("proxy_connectivity")) {
        ai_heal_report(incident.type, incident.description,
            "Очищена база cache.db; перезапуск пропущен по лимиту частоты", "skipped");
        return;
    }
    watch_recovery("proxy", EV.PROXY_UP, incident);
}

// ─── Subnet cache restore: /etc/tachyon/rulesets/ → /tmp/sing-box/rulesets/ ──
function ai_heal_subnet_cache() {
    let etc_dir = "/etc/tachyon/rulesets";
    let tmp_dir = "/tmp/sing-box/rulesets";

    let dir = fs.opendir(etc_dir);
    if (!dir) return;

    let restored = [];
    let entry;
    while ((entry = dir.read()) != null) {
        if (!match(entry, /^community-subnets-.+\.lst$/)) continue;
        let tmp_path = tmp_dir + "/" + entry;
        let etc_path = etc_dir + "/" + entry;
        let tmp_st = fs.stat(tmp_path);
        let etc_st = fs.stat(etc_path);
        if (!helpers.file_is_usable(etc_path, 50)) continue;
        if (helpers.file_is_usable(tmp_path, 50)) continue;
        // /tmp file missing or empty, restore from persistent storage
        let content = fs.readfile(etc_path);
        if (content == null || content == "") continue;
        // Ensure /tmp dir exists
        command_success_from_args(["mkdir", "-p", tmp_dir]);
        if (fs.writefile(tmp_path, content) != null) {
            push(restored, entry);
        }
    }
    dir.close();

    if (length(restored) > 0) {
        let names = join(", ", restored);
        log_message("Subnet cache restored from /etc to /tmp: " + names, "info");
    }
}

// ─── Check nft sets are populated (community subnets) ─────────────────────────
function heal_community_subnet_sets(ev) {
    if (settings().recovery_bypass == "1") return;

    for (let set_name in common.array_or_empty(ev.payload.sets))
        log_message("Community subnet set " + set_name + " is empty — will repopulate", "warn");

    ai_heal_subnet_cache();
    ai_heal_report(
        "nft_community_sets",
        "Пустые nftables sets подсетей (community) — данные не были загружены при reload",
        "Восстановлены nftables sets из persistent кеша (/etc/tachyon/rulesets/)",
        "fixed"
    );
    bg_system("/usr/bin/tachyon reload_firewall </dev/null >/dev/null 2>&1 &");
}


// ─── TPROXY port liveness ─────────────────────────────────────────────────────
function heal_tproxy_port(ev) {
    if (settings().recovery_bypass == "1") return;

    ai_heal_report(
        "tproxy_port",
        sprintf("TPROXY порт %d не слушает — правила перехвата трафика не работают", int(ev.payload.port)),
        "Выполнен reload_firewall для восстановления TPROXY правил",
        "fixed"
    );
    safe_reload_firewall();
}

function heal_wan_and_gateway(ev) {
    let tcfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
    if (tcfg.notify_crash != "0") {
        send_telegram_notification("⚠️ *Watchdog:* WAN/Gateway проблема. Перезапуск wan...");
    }
    bg_system("/sbin/ifdown wan >/dev/null 2>&1 && /sbin/ifup wan >/dev/null 2>&1 &");
}

function heal_subscriptions(ev) {
    let tcfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
    if (tcfg.notify_crash != "0") {
        send_telegram_notification("⚠️ *Watchdog:* Подписка недоступна (HTTP " + int(ev.payload.code) + "). Обновите подписку вручную.");
    }
}

function heal_uci_config(ev) {
    let tcfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
    if (tcfg.notify_crash != "0") {
        send_telegram_notification("⚠️ *Watchdog:* Конфигурация Tachyon повреждена! Восстановление из backup...");
    }
    let backup = fs.readfile("/etc/backup/tachyon_config");
    if (backup == null || backup == "") return;

    let valid = command_success_from_args([ "uci", "-c", "/etc/config", "valid", CONFIG_NAME ]) ||
                command_success_from_args([ "/sbin/uci", "valid", CONFIG_NAME ]);
    if (!valid) {
        log_message("Backup config also invalid, skipping restore", "warn");
        return;
    }
    let tmp = "/etc/config/tachyon.restore-tmp";
    if (fs.writefile(tmp, backup) != null) {
        fs.rename(tmp, "/etc/config/tachyon");
        system("chmod 0600 /etc/config/tachyon 2>/dev/null");
        safe_proxy_restart("uci_config_restore");
    }
}

// ─── AI Settings helpers ──────────────────────────────────────────────────────
function ai_setting(key, default_val) {
    let cfg = settings();
    let val = cfg[key];
    return val != null ? as_string(val) : as_string(default_val);
}
function ai_enabled(key, default_val) {
    return ai_setting(key, default_val) == "1";
}

// ─── Config validation: sing-box check ────────────────────────────────────────
function validate_singbox_config() {
    if (!ai_enabled("ai_config_validation_enabled", "1")) return true;
    return command_success_from_args(["sing-box", "check", "-c", "/etc/sing-box/config.json"]);
}

// ─── Proxy Health Monitor ─────────────────────────────────────────────────────
// The second proxy subscriber: where heal_proxy_connectivity() reacts to a
// single failure with a working uplink, this one waits for a configurable run
// of failures and validates the sing-box config before restarting.
function heal_proxy_health(ev) {
    if (!ai_enabled("ai_proxy_health_enabled", "1")) return;

    let threshold = int(ai_setting("ai_proxy_health_fail_threshold", "3"));
    let fails = int(ev.payload.streak);
    if (fails < threshold) return;

    let incident = {
        type: "proxy_health",
        description: sprintf("Proxy health check failed %d times consecutively (port %s)", fails, as_string(ev.payload.port)),
        resolution: "Restarting Tachyon to restore proxy connectivity"
    };

    // A restart on a config sing-box will refuse to load leaves the proxy down
    // for good, so validation gates the restart. It now also gates the report:
    // a refused restart is not a repair.
    if (ai_enabled("ai_config_validation_enabled", "1") && !validate_singbox_config()) {
        log_message("sing-box config validation failed before proxy restart", "err");
        ai_heal_report(incident.type, incident.description,
            "Перезапуск отменён: конфигурация sing-box не проходит валидацию", "skipped");
        return;
    }
    if (!safe_proxy_restart("proxy_health")) {
        ai_heal_report(incident.type, incident.description,
            "Перезапуск пропущен по лимиту частоты", "skipped");
        return;
    }
    controller.reset_proxy_consecutive();
    watch_recovery("proxy", EV.PROXY_UP, incident);
}

// ─── DNS Continuous Check ─────────────────────────────────────────────────────
// The second DNS subscriber: restores dnsmasq's own configuration rather than
// restarting the proxy, so it is complementary to heal_dns_stall().
function heal_dns_continuous(ev) {
    if (!ai_enabled("ai_dns_continuous_enabled", "1")) return;
    if (int(ev.payload.consecutive) < 3) return;

    // Synchronous repair: uci and the dnsmasq reload both return before this
    // function does, so the outcome is known here and needs no recovery watch.
    system("/sbin/uci set dhcp.@dnsmasq[0].noresolv='1' >/dev/null 2>&1");
    system("/sbin/uci commit dhcp >/dev/null 2>&1");
    let rc = system("/etc/init.d/dnsmasq reload >/dev/null 2>&1");
    controller.reset_dns_consecutive();

    ai_heal_report(
        "dns_continuous",
        "DNS resolution failed 3 times consecutively",
        "Restoring dnsmasq config and reloading",
        rc == 0 ? "fixed" : "failed"
    );
}

// ─── AI Empty Sections Recovery ─────────────────────────────────────────────
function heal_empty_sections(ev) {
    let recovered = common.array_or_empty(ev.payload.sections);
    if (length(recovered) == 0) return;

    for (let name in recovered) {
        log_message("Empty proxy section '" + name + "' — triggering subscription update", "warn");
        bg_system("/usr/bin/tachyon subscription_update_async " + common.shell_quote(name) + " </dev/null >/dev/null 2>&1 1000<&- &");
    }

    ai_heal_report(
        "empty_proxy_sections",
        "Empty proxy sections detected: " + join(", ", recovered),
        "Auto-triggering subscription update for " + as_string(length(recovered)) + " section(s)",
        "fixed"
    );
}

// ─── DNS Loop Recovery (dead proxy + DNS detour = total DNS loss) ────────────
let DNS_RECOVERY_STATE_FILE = "/var/run/tachyon/dns-detour-recovery.json";
let dns_recovery_active = false;

function is_dns_dead() {
    return !is_dns_working();
}

function read_dns_recovery_state() {
    let data = common.read_json_file(DNS_RECOVERY_STATE_FILE);
    return common.object_or_empty(data);
}

function write_dns_recovery_state(state) {
    common.write_json_file(DNS_RECOVERY_STATE_FILE, state);
}

function remove_dns_recovery_state() {
    try { fs.unlink(DNS_RECOVERY_STATE_FILE); } catch(e) {}
}

// Kept as a self-contained check rather than a fact subscriber: it needs the
// *current* resolver state at the moment it acts (it re-tests DNS to decide
// whether to re-enable the detour), so acting on a fact observed earlier in the
// tick could re-enable a detour against a resolver that has since died.
function ai_heal_dns_loop() {
    if (!ai_enabled("ai_dns_loop_heal_enabled", "1")) return;
    if (is_reload_in_progress()) return;
    let now = time();

    let cfg = settings();
    let detour_enabled = common.bool_option(cfg, "dns_detour_enabled", false);
    if (!detour_enabled) return;

    let detour_section = common.option(cfg, "dns_detour_section", "");
    if (detour_section == "") return;

    // Check if DNS is dead
    if (!is_dns_dead()) {
        // DNS works — if we were in recovery, try to restore
        let recovery = read_dns_recovery_state();
        if (recovery.phase == "detour_disabled") {
            let reenable_cooldown = recovery.ts ? (now - int(recovery.ts)) : 0;
            if (reenable_cooldown < 300) return;
            let test_dns = is_dns_working();
            if (test_dns) {
                log_message("DNS loop recovery: DNS works, re-enabling DNS detour section", "info");
                system("/sbin/uci set tachyon.settings.dns_detour_enabled='1' >/dev/null 2>&1");
                system("/sbin/uci commit tachyon >/dev/null 2>&1");
                safe_proxy_restart("dns_loop_recovery");
                remove_dns_recovery_state();
                ai_heal_report(
                    "dns_loop_recovery",
                    "DNS recovered with detour re-enabled",
                    "Restored DNS detour section " + detour_section,
                    "fixed"
                );
            }
        }
        return;
    }

    // DNS is dead — check if detour section has outbounds
    let recovery = read_dns_recovery_state();
    if (recovery.phase == "detour_disabled") {
        // Already in recovery — just wait and retry
        log_message("DNS loop recovery: DNS still dead, retrying subscription update", "info");
        bg_system("/usr/bin/tachyon subscription_update_async " + common.shell_quote(detour_section) + " </dev/null >/dev/null 2>&1 1000<&- &");
        return;
    }

    // Check if detour section is empty
    let cache_path = "/var/run/tachyon/section-cache/" + detour_section + ".json";
    let cache = common.object_or_empty(common.read_json_file(cache_path));
    let servers = common.array_or_empty(cache.servers);
    let urls = common.array_or_empty(cache.urls);
    let usable = length(servers) + length(urls);

    if (usable > 0) {
        // Section has outbounds but DNS is still dead — may be transient
        return;
    }

    // Detour section empty AND DNS dead — disable DNS detour to recover
    log_message("DNS loop detected: DNS detour section '" + detour_section + "' is empty, disabling DNS detour to recover", "warn");
    system("/sbin/uci set tachyon.settings.dns_detour_enabled='0' >/dev/null 2>&1");
    system("/sbin/uci commit tachyon >/dev/null 2>&1");
    safe_proxy_restart("dns_loop_disable");
    write_dns_recovery_state({ phase: "detour_disabled", section: detour_section, ts: now });

    // Trigger subscription update for the empty section
    bg_system("/usr/bin/tachyon subscription_update_async " + common.shell_quote(detour_section) + " </dev/null >/dev/null 2>&1 1000<&- &");

    ai_heal_report(
        "dns_loop_detected",
        "DNS loop: detour section '" + detour_section + "' has 0 outbounds, DNS completely dead",
        "Temporarily disabled DNS detour to restore DNS, triggered subscription reload",
        "fixed"
    );
}

// ─── Metrics helpers ──────────────────────────────────────────────────────────
// Defined before export_metrics to ensure forward-reference safety in ucode
// closure/timer contexts (see issue #14).
function average_latency(history) {
    let sum = 0;
    let count = 0;
    for (let entry in history) {
        if (entry.ok) {
            sum += entry.ms;
            count++;
        }
    }
    return count > 0 ? int(sum / count) : -1;
}

// ─── Metrics export (normal tier) ─────────────────────────────────────────────
function export_metrics() {
    if (!ai_enabled("ai_metrics_enabled", "1")) return;

    let now = time();
    let metrics_path = "/tmp/tachyon_metrics.json";
    let data = { hours: [] };
    let existing = fs.readfile(metrics_path);
    if (existing) {
        try { data = json(existing) || data; } catch(e) {}
    }

    let hour_bucket = int(now / 3600) * 3600;
    let last_bucket = length(data.hours) > 0 ? data.hours[length(data.hours) - 1] : null;
    if (last_bucket && int(last_bucket.ts) == hour_bucket) {
        last_bucket.proxy_ok = proxy_consecutive_fails() == 0;
        last_bucket.proxy_lat_ms = average_latency(proxy_latency_history());
        last_bucket.dns_lat_ms = average_latency(dns_latency_history());
        last_bucket.incidents = ai_incidents_count;
    } else {
        push(data.hours, {
            ts: hour_bucket,
            proxy_ok: proxy_consecutive_fails() == 0,
            proxy_lat_ms: average_latency(proxy_latency_history()),
            dns_lat_ms: average_latency(dns_latency_history()),
            incidents: ai_incidents_count
        });
    }

    let retention = int(ai_setting("ai_metrics_retention_hours", "24"));
    while (length(data.hours) > retention)
        data.hours = slice(data.hours, 1);

    fs.writefile(metrics_path, sprintf("%J\n", data));
}

// ─── Anomaly Detection ────────────────────────────────────────────────────────
function heal_anomaly_reconnects(ev) {
    if (!ai_enabled("ai_anomaly_detection_enabled", "1")) return;

    ai_heal_report(
        "anomaly_reconnects",
        sprintf("sing-box reconnected %d times in the last hour (threshold: %d)",
            int(ev.payload.count), int(ev.payload.threshold)),
        "High reconnect rate detected. Check proxy server health or ISP stability.",
        "warn"
    );
    fs.writefile("/tmp/tachyon_reconnect_count", "0\n");
}

function increment_reconnect_count() {
    let count_file = "/tmp/tachyon_reconnect_count";
    let count = int(trim(fs.readfile(count_file) || "0")) + 1;
    fs.writefile(count_file, as_string(count) + "\n");
}

// ─── Adaptive Intervals ───────────────────────────────────────────────────────
function adaptive_normal_interval() {
    return controller.adaptive_normal_interval();
}

// ─── Graceful Degradation wrapper ─────────────────────────────────────────────
// Still used for the few actions that are not bus subscribers (the metrics
// export, smart-detect batch processing, the ai-heal CLI audit). Subscribers
// get the same isolation from the bus itself.
function safe_call(fn, name) {
    if (!ai_enabled("ai_graceful_degradation_enabled", "1")) {
        fn();
        return;
    }
    try {
        fn();
    } catch(e) {
        log_message("Graceful degradation: " + name + " failed: " + as_string(e), "err");
    }
}

// ─── rpcd FD leak ─────────────────────────────────────────────────────────────
function heal_rpcd(ev) {
    // Synchronous restart, so its exit status is the outcome.
    let rc = system("/etc/init.d/rpcd restart </dev/null >/dev/null 2>&1");
    ai_heal_report(
        "rpcd_fd_leak",
        sprintf("rpcd накопил %d открытых FD (порог %d/1024) — LuCI не может запускать команды",
            int(ev.payload.fd_count), int(ev.payload.threshold)),
        "Выполнен перезапуск rpcd для освобождения файловых дескрипторов",
        rc == 0 ? "fixed" : "failed"
    );
}

// ─── Low memory ───────────────────────────────────────────────────────────────
// Deliberately silent: dropping caches is routine housekeeping, not an
// incident, so it never called ai_heal_report() and still does not.
function heal_low_memory(ev) {
    log_message("Low memory detected (" + as_string(ev.payload.free_mb) + "MB). Clearing caches...", "warn");
    system("echo 3 > /proc/sys/vm/drop_caches");
}

// The 5s throttle that used to live here is now the controller's emit_once
// window on urltest.switched, so a burst of log lines still costs one poll.
function notify_urltest_switch(ev) {
    let tcfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
    if (tcfg.enabled != "1" || tcfg.notify_crash == "0") return;

    let p_res = command_capture(command_from_args(["curl", "-s", "http://127.0.0.1:4534/proxies"]));
    if (p_res && p_res.status == 0 && p_res.output) {
        try {
            let p_data = json(p_res.output);
            let proxies = p_data.proxies;
            for (let name in proxies) {
                let p = proxies[name];
                if (p.type == "URLTest" && p.now) {
                    let safe_name = replace(name, /[^a-zA-Z0-9_\-]/g, "_");
                    let last_now = trim(fs.readfile("/tmp/watchdog_urltest_" + safe_name) || "");
                    if (last_now != "" && last_now != p.now) {
                        send_telegram_notification("🔀 *Watchdog:* Смена прокси в группе `" + name + "`\nНовый активный узел: `" + p.now + "`");
                    }
                    fs.writefile("/tmp/watchdog_urltest_" + safe_name, p.now);
                }
            }
        } catch(e) {}
    }
}

function smart_detect_process_pending() {
    let cfg = settings();
    if (cfg.smart_detect != "1") {
        pending_smart_domains = {};
        return;
    }
    let now = time();
    if (now - smart_detect_last_run < 30) return;

    let domain_list = keys(pending_smart_domains);
    if (length(domain_list) == 0) return;
    smart_detect_last_run = now;

    let seen = {};
    let seen_data = fs.readfile(SMART_DETECT_SEEN_FILE);
    if (seen_data) {
        try { seen = json(seen_data) || {}; } catch(e) {}
    }

    let candidate_domains = [];
    for (let dom in domain_list) {
        if (!seen[dom]) {
            push(candidate_domains, dom);
        }
    }
    pending_smart_domains = {};

    if (length(candidate_domains) == 0) return;

    let sections = smart_detect_get_proxy_sections();
    if (length(sections) == 0) return;

    let proxy_addr = "127.0.0.1:4534";
    let sb_cfg_data = fs.readfile("/etc/sing-box/config.json");
    if (sb_cfg_data) {
        try {
            let sb_cfg = json(sb_cfg_data);
            if (sb_cfg.inbounds) {
                for (let inb in sb_cfg.inbounds) {
                    if (inb.type == "http" || inb.type == "mixed") {
                        proxy_addr = "127.0.0.1:" + as_string(inb.listen_port || 4534);
                        break;
                    }
                }
            }
        } catch(e) {}
    }

    let detect_sections = [];
    let raw_list = cfg.smart_detect_sections;
    if (type(raw_list) == "array") {
        detect_sections = raw_list;
    } else if (raw_list && trim(as_string(raw_list)) != "") {
        detect_sections = [ trim(as_string(raw_list)) ];
    }
    if (length(detect_sections) == 0) {
        detect_sections = sections;
    }

    for (let domain in candidate_domains) {
        try {
        seen[domain] = now;

        // DNS pre-check: skip if domain doesn't resolve at all (not a block, DNS fault)
        if (!smart_detect_domain_resolves(domain)) {
            log_message("Smart Detect: " + domain + " does not resolve via DNS, skipping", "debug");
            continue;
        }

        let direct_ok = command_success_from_args([
            "curl", "-s", "-I", "--connect-timeout", "4", "--max-time", "6",
            "https://" + domain
        ]);
        if (direct_ok) continue;

        // Single probe through the shared http/mixed inbound. This inbound follows
        // the global routing rules, so it cannot be aimed at one specific section:
        // the result is the same for every candidate section. Probe once, then hand
        // the domain to the first section that accepts it (user-defined order).
        let proxy_ok = command_success_from_args([
            "curl", "-s", "-I", "--connect-timeout", "5", "--max-time", "8",
            "--proxy", "http://" + proxy_addr,
            "https://" + domain
        ]);
        if (!proxy_ok) {
            log_message("Smart Detect: " + domain + " fails directly and via proxy, skipping", "info");
            continue;
        }

        let added = false;
        for (let sec_name in detect_sections) {
            sec_name = trim(as_string(sec_name));
            if (sec_name == "") continue;

            log_message("Smart Detect: adding " + domain + " to section " + sec_name, "info");
            if (smart_detect_add_domain(sec_name, domain)) {
                let tcfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
                if (tcfg.enabled == "1" && tcfg.bot_token && tcfg.admin_ids) {
                    send_telegram_notification(
                        "🔍 *Smart Detect*: `" + domain + "` недоступен напрямую, работает через прокси.\nДобавлен в секцию *" + sec_name + "*."
                    );
                }
                added = true;
                break;
            }
        }
        if (!added) {
            log_message("Smart Detect: domain " + domain + " not handled by any section", "info");
        }
        } catch (e) {
            log_message("Smart Detect: failed to process " + domain + ": " + as_string(e), "err");
        }
    }

    let clean = {};
    let cutoff = now - 86400;
    for (let k in keys(seen)) {
        if (seen[k] >= cutoff) clean[k] = seen[k];
    }
    fs.writefile(SMART_DETECT_SEEN_FILE, sprintf("%J", clean));
}

// ─── OOM response ─────────────────────────────────────────────────────────────
// Shrinks the GOMEMLIMIT scale by 20% per OOM, floored at 0.2 so sing-box is
// never starved into permanent failure, then restarts to apply it.
function heal_oom(ev) {
    log_message("OOM event detected from syslog! Reducing GOMEMLIMIT scaling...", "err");
    send_telegram_notification("🚨 *Watchdog:* Обнаружено событие OOM (Out Of Memory)! Уменьшаю GOMEMLIMIT и перезапускаю службы...");
    let scale = 1.0;
    let scale_path = "/etc/tachyon/mem_scale";
    let scale_data = fs.readfile(scale_path);
    if (scale_data != null) {
        let parsed_scale = double(trim(as_string(scale_data)));
        if (parsed_scale > 0.1) scale = parsed_scale;
    }
    let new_scale = scale * 0.8;
    if (new_scale < 0.2) new_scale = 0.2;
    fs.mkdir("/etc/tachyon");
    fs.writefile(scale_path, sprintf("%.2f", new_scale));
    system("logread -c >/dev/null 2>&1");
    command_status("/usr/bin/tachyon restart >/dev/null 2>&1");
}

// Candidate domains are queued here and probed in a batch by
// smart_detect_process_pending(): probing inside the log handler would block
// the event loop on curl for every failing connection.
function collect_smart_detect_candidate(ev) {
    pending_smart_domains[ev.payload.domain] = time();
}

// ─── Honeypot ─────────────────────────────────────────────────────────────────
// The controller has already validated the address shape, so nothing
// unvalidated reaches the nft command line here.
function heal_honeypot_hit(ev) {
    let cfg = settings();
    let ttl = cfg.honeypot_ttl || "86400";
    let nft_table = getenv("NFT_TABLE_NAME") || "TachyonTable";
    command_success_from_args(["nft", "add", "element", "inet", nft_table, "tachyon_honeypot",
        "{", ev.payload.ip, "timeout", ttl + "s", "}"]);
}

function setup_honeypot_listener() {
    system("mkfifo /tmp/tachyon_honeypot.fifo >/dev/null 2>&1");
    system("chmod 0660 /tmp/tachyon_honeypot.fifo >/dev/null 2>&1");

    let hp_pid = trim(fs.readfile("/var/run/tachyon_honeypot_listener.pid") || "");
    if (hp_pid != "" && match(hp_pid, /^[0-9]+$/) != null) {
        if (process_running(hp_pid)) {
            command_success_from_args([ "kill", hp_pid ]);
            let wait_limit = 20;
            while (wait_limit > 0 && process_running(hp_pid)) {
                sleep(100);
                wait_limit--;
            }
            if (process_running(hp_pid)) {
                command_success_from_args([ "kill", "-9", hp_pid ]);
            }
        }
    }
    remove_file("/var/run/tachyon_honeypot_listener.pid");

    let fifo_fd = fs.open("/tmp/tachyon_honeypot.fifo", "r+");
    if (uloop && fifo_fd) {
        try {
            uloop.handle(fifo_fd.fileno(), function(events) {
                let line;
                while ((line = fifo_fd.read("line")) != null) {
                    controller.handle_honeypot_line(line);
                }
            }, uloop.ULOOP_READ);
        } catch (e) {
            log_message("Failed to bind honeypot fifo to uloop: " + as_string(e), "warn");
        }
    } else {
        let cfg = settings();
        let ttl = cfg.honeypot_ttl || "86400";
        let nft_table = getenv("NFT_TABLE_NAME") || "TachyonTable";
        let hp_cmd = "tail -f /tmp/tachyon_honeypot.fifo | while read ip; do " +
            "if [ -n \"$ip\" ]; then " +
            "nft add element inet " + shell_quote(nft_table) + " tachyon_honeypot { \"$ip\" timeout " + shell_quote(ttl) + "s } >/dev/null 2>&1; " +
            "fi; done </dev/null >/dev/null 2>&1 1000<&- & echo $! > /var/run/tachyon_honeypot_listener.pid";
        system(hp_cmd);
    }
}

// The "OOM was long enough ago" and "scale is below 1.0" tests are the
// controller's oom.recovery probe; what is left here is the write-back.
// The 600s self-cooldown stays local because it paces the healer, not the fact.
function recover_oom_scale(ev) {
    let now = time();
    if (now - last_oom_recovery_time < 600) return;
    last_oom_recovery_time = now;

    let scale_path = "/etc/tachyon/mem_scale";
    let current_scale = double(ev.payload.scale);
    let new_scale = current_scale + 0.05;
    if (new_scale > 1.0) new_scale = 1.0;
    log_message("OOM recovery: restoring GOMEMLIMIT scale from " + sprintf("%.2f", current_scale) + " to " + sprintf("%.2f", new_scale), "info");
    try { fs.writefile(scale_path, sprintf("%.2f", new_scale)); } catch(e) {}
}

function setup_syslog_listener() {
    if (!uloop) return null;
    controller.set_syslog_start(time());
    // Kill orphaned logread -f processes from previous watchdog instances.
    // Without this, every restart cascades: new watchdog inherits old watchdog's
    // logread pipe read-end, keeping old logread alive. Over N restarts,
    // watchdog accumulates N inherited FDs → hits 1024 limit → config generator fails.
    // Use pkill to target only logread in follow mode, not one-shot logread calls.
    system("pkill -f 'logread -f' 2>/dev/null; true");
    let log_pipe = fs.popen("logread -f 2>/dev/null", "r");
    if (!log_pipe) return null;
    // Track the FD so bg_system() can close it before spawning background processes
    logread_pipe_fd = log_pipe.fileno();

    try {
        uloop.handle(log_pipe.fileno(), function(events) {
            let line;
            while ((line = log_pipe.read("line")) != null) {
                controller.handle_log_line(trim(as_string(line)));
            }
        }, uloop.ULOOP_READ);
    } catch (e) {
        log_message("Failed to register syslog listener: " + as_string(e), "warn");
    }
    return log_pipe;
}

function setup_ubus_listener() {
    if (!ubus || !uloop) return null;
    let conn = null;
    try { conn = ubus.connect(); } catch (e) {}
    if (!conn || type(conn.listener) != "function") return null;

    try {
        conn.listener("service.instance.stop", function(ev, msg) {
            if (type(msg) == "object")
                controller.handle_ubus_service_stop(msg.name, "ubus service.instance.stop event");
        });
        conn.listener("service.stop", function(ev, msg) {
            if (type(msg) == "object")
                controller.handle_ubus_service_stop(msg.name, "ubus service.stop event");
        });
        conn.listener("firewall.reload", function(ev, msg) {
            controller.handle_ubus_firewall_reload();
        });
    } catch (e) {
        log_message("Failed to register ubus listeners: " + as_string(e), "warn");
    }
    return conn;
}

// Idempotent: the ai-heal CLI mode and worker() both need the subscriptions in
// place, and registering twice would double every repair.
let subscribers_registered = false;

// ─── Subscriptions ────────────────────────────────────────────────────────────
// One table, one place: what the watchdog reacts to and in what order. Priority
// encodes the old tier ordering — restore the uplink before blaming the proxy,
// restore the proxy before touching DNS — so a single tick that observes several
// faults repairs them bottom-up like the sequential check list used to.
//
// `cooldown` values are the module globals the old code hand-rolled:
//   heal_wan_and_gateway     ← last_wan_heal_time      (300s)
//   heal_community_subnet…   ← last_subnet_heal_time   (300s)
//   heal_empty_sections      ← last_section_heal_attempt (120s)
//   heal_anomaly_reconnects  ← last_anomaly_check      (300s)
// Debounces that belong to the repair rather than the fact (the 30s sing-box
// restart floor, the 600s OOM-recovery pacing) stay inside their handlers.
// A handler that is not a function makes bus.on() return false and register
// nothing — the repair would then silently never run, with no error anywhere.
// ucode does not hoist function declarations, so that is exactly what happens if
// a heal_* is moved below this function. subscribe() turns that silent loss into
// a startup failure.
function subscribe(event_type, handler, opts) {
    if (!bus.on(event_type, handler, opts)) {
        let label = (type(opts) == "object" && opts.name != null) ? opts.name : as_string(event_type);
        log_message("FATAL: subscriber " + label + " for " + as_string(event_type) +
            " could not be registered; this repair would never run", "err");
        die("watchdog: failed to register subscriber " + label);
    }
}

function register_subscribers() {
    if (subscribers_registered) return;
    subscribers_registered = true;

    subscribe(EV.WAN_DOWN, heal_wan_and_gateway,
        { name: "heal_wan_and_gateway", priority: 10, cooldown: 300 });

    subscribe(EV.SINGBOX_STOPPED, heal_singbox_stopped,
        { name: "heal_singbox_stopped", priority: 20 });

    subscribe(EV.CONFIG_CORRUPT, heal_uci_config,
        { name: "heal_uci_config", priority: 25 });

    subscribe(EV.NFT_MISSING, heal_nftables,
        { name: "heal_nftables", priority: 30 });
    subscribe(EV.QOS_MISSING, heal_qos,
        { name: "heal_qos", priority: 30 });
    subscribe(EV.TPROXY_DOWN, heal_tproxy_port,
        { name: "heal_tproxy_port", priority: 30 });
    subscribe(EV.SUBNETS_EMPTY, heal_community_subnet_sets,
        { name: "heal_community_subnet_sets", priority: 30, cooldown: 300 });

    // Both proxy subscribers see the same fact, but they used to be measured on
    // different tiers, and their thresholds are calibrated to those rates:
    // ai_heal_proxy_health ran fast (15s), ai_heal_proxy_connectivity ran inside
    // the normal-tier audit (120s+). The probe now runs once at the fast rate,
    // so the connectivity healer carries a 120s cooldown to keep its original
    // pacing. Without it a single stall would restart sing-box eight times as
    // often — the aggressive-restart regression fixed in c8052ee6.
    subscribe(EV.PROXY_DOWN, heal_proxy_connectivity,
        { name: "heal_proxy_connectivity", priority: 40, cooldown: 120 });
    subscribe(EV.PROXY_DOWN, heal_proxy_health,
        { name: "heal_proxy_health", priority: 41 });

    // Same split for DNS: ai_heal_dns_continuous was fast, ai_heal_dns was part
    // of the normal-tier audit. The streak the stall healer thresholds on is
    // already paced at the normal rate inside the probe (DNS_STREAK_INTERVAL);
    // the cooldown here is a second bound on how often a restart can be issued,
    // so a streak that stays at 3 cannot restart the proxy every 15 seconds.
    subscribe(EV.DNS_DOWN, heal_dns_stall,
        { name: "heal_dns_stall", priority: 50, cooldown: 120 });
    subscribe(EV.DNS_DOWN, heal_dns_continuous,
        { name: "heal_dns_continuous", priority: 51 });

    // Recovery facts. These were published from the start but had no subscriber,
    // which is why a repair could only ever report its own intent. No cooldown:
    // settle_recovery() is a no-op unless a watch is actually open, and skipping
    // the one emit that closes a watch would leave it to expire as `failed`.
    subscribe(EV.PROXY_UP, note_proxy_recovered,
        { name: "note_proxy_recovered", priority: 5 });
    subscribe(EV.DNS_UP, note_dns_recovered,
        { name: "note_dns_recovered", priority: 5 });

    subscribe(EV.SECTIONS_EMPTY, heal_empty_sections,
        { name: "heal_empty_sections", priority: 60, cooldown: 120 });
    subscribe(EV.SUBSCRIPTION_UNREACHABLE, heal_subscriptions,
        { name: "heal_subscriptions", priority: 60 });

    subscribe(EV.OOM_DETECTED, heal_oom,
        { name: "heal_oom", priority: 70 });
    subscribe(EV.OOM_RECOVERABLE, recover_oom_scale,
        { name: "recover_oom_scale", priority: 70 });
    subscribe(EV.MEMORY_LOW, heal_low_memory,
        { name: "heal_low_memory", priority: 70 });
    subscribe(EV.RPCD_FD_LEAK, heal_rpcd,
        { name: "heal_rpcd", priority: 70 });

    subscribe(EV.ANOMALY_RECONNECTS, heal_anomaly_reconnects,
        { name: "heal_anomaly_reconnects", priority: 80, cooldown: 300 });

    // Observers, not repairs: they must run after the healers above.
    subscribe(EV.SMARTDETECT_CANDIDATE, collect_smart_detect_candidate,
        { name: "collect_smart_detect_candidate", priority: 90 });
    subscribe(EV.URLTEST_SWITCHED, notify_urltest_switch,
        { name: "notify_urltest_switch", priority: 90 });
    subscribe(EV.HONEYPOT_HIT, heal_honeypot_hit,
        { name: "heal_honeypot_hit", priority: 90 });
    subscribe(EV.PAUSE_EXPIRED, function(ev) { check_auto_resume_pause(); },
        { name: "resume_after_pause", priority: 5 });
}

// One synchronous sweep of every tier, used by the `ai-heal` CLI mode where no
// worker is running: probe, let the subscribers repair, then publish status.
function ai_full_health_audit() {
    register_subscribers();
    controller.probe_fast();
    controller.probe_normal();
    controller.probe_slow();
    safe_call(ai_heal_dns_loop, "ai_heal_dns_loop");
    safe_call(settle_expired_recoveries, "settle_expired_recoveries");
    ai_export_status();
}

function worker() {
    log_message("Watchdog daemon started.", "info");

    // Subscribe before any source is wired up, so no fact observed during
    // startup is published into an empty bus and lost.
    register_subscribers();

    setup_honeypot_listener();
    // Restore subnet cache from persistent storage at startup (in case /tmp was cleared)
    ai_heal_subnet_cache();
    run_zero_rtt_prefetching();

    // Ensure /etc/tachyon exists for persistent smart detect
    try { fs.mkdir("/etc/tachyon"); } catch(e) {}

    // H-14: Save config backup after successful start
    let current_cfg = fs.readfile("/etc/config/tachyon");
    if (current_cfg != null && current_cfg != "") {
        try { fs.writefile("/etc/backup/tachyon_config", current_cfg); } catch(e) {}
    }

    // H-8: Write keepalive timestamp for init.d supervision
    try { fs.writefile("/var/run/tachyon_watchdog.keepalive", as_string(time())); } catch(e) {}

    if (uloop) {
        try {
            uloop.init();
        } catch (e) {
            log_message("Failed to initialize uloop: " + as_string(e), "warn");
        }
    }

    let log_pipe = setup_syslog_listener();
    let ubus_conn = setup_ubus_listener();

    function perform_fast_checks() {
        controller.probe_fast();
        // After the probes, so a recovery observed on this very tick closes its
        // watch before the deadline is tested against it.
        safe_call(settle_expired_recoveries, "settle_expired_recoveries");
    }

    function perform_normal_checks() {
        controller.probe_normal();
        safe_call(smart_detect_process_pending, "smart_detect_process_pending");
        safe_call(export_metrics, "export_metrics");
        safe_call(ai_export_status, "ai_export_status");
    }

    function perform_slow_checks() {
        controller.probe_slow();
        safe_call(ai_heal_dns_loop, "ai_heal_dns_loop");
    }

    if (uloop) {
        let tick;
        tick = function() {
            let now = time();
            try {
                try { fs.writefile("/var/run/tachyon_watchdog.keepalive", as_string(time())); } catch(e) {}
                if (now - last_fast_check >= 15) {
                    last_fast_check = now;
                    perform_fast_checks();
                }
                if (now - last_normal_check >= adaptive_normal_interval()) {
                    last_normal_check = now;
                    perform_normal_checks();
                }
                if (now - last_slow_check >= 300) {
                    last_slow_check = now;
                    perform_slow_checks();
                }
            } catch (e) {
                log_message("Error in tick: " + as_string(e), "err");
            }
            uloop.timer(5000, tick);
        };
        uloop.timer(10000, tick);

        log_message("Watchdog running in event-driven uloop mode (fast: 15s, normal: adaptive, slow: 300s).", "info");
        uloop.run();
    } else {
        log_message("uloop not available. Running Watchdog in legacy fallback loop mode.", "warn");
        signal("SIGTERM", function(sig) { log_message("SIGTERM received, shutting down", "info"); stop_runtime(); exit(0); });
        signal("SIGINT", function(sig) { log_message("SIGINT received, shutting down", "info"); stop_runtime(); exit(0); });
        while (true) {
            perform_fast_checks();
            perform_normal_checks();
            perform_slow_checks();
            sleep(15000);
        }
    }

    if (log_pipe) log_pipe.close();
    if (ubus_conn) try { ubus_conn.close(); } catch (e) {}
    return 0;
}

function get_status() {
    let pid = trim(fs.readfile(PID_FILE) || "");
    if (process_running(pid, "ucode")) {
        print("running (pid " + pid + ")\n");
        return 0;
    }
    print("stopped\n");
    return 1;
}

function print_ai_status() {
    let data = fs.readfile("/tmp/tachyon_ai_status.json");
    if (data) {
        print(data);
    } else {
        print("{\"status\":\"unknown\",\"ai_active\":false}\n");
    }
}

function print_ai_status_full() {
    let now = time();
    let proxy_fails = proxy_consecutive_fails();
    let dns_fails = dns_consecutive_fails();
    let proxy_ok = proxy_fails == 0;
    let dns_ok = dns_fails == 0;

    let sb_uptime = 0;
    let sb_pid = get_sing_box_pid();
    if (sb_pid != "" && process_running(sb_pid, "sing-box")) {
        try {
            let stat_data = fs.readfile("/proc/" + sb_pid + "/stat");
            if (stat_data) {
                let fields = split(trim(stat_data), /[ \t]+/);
                if (length(fields) >= 22) {
                    let starttime = int(fields[21]);
                    let clk_tck = 100;
                    let uptime_seconds = 0;
                    try { uptime_seconds = int(trim(fs.readfile("/proc/uptime") || "0")); } catch(e) {}
                    sb_uptime = uptime_seconds - int(starttime / clk_tck);
                }
            }
        } catch(e) {}
    }

    let mem_mb = -1;
    let mem_info = fs.readfile("/proc/meminfo") || "";
    for (let line in split(mem_info, "\n")) {
        if (index(line, "MemAvailable:") == 0) {
            let fields = split(trim(line), /[ \t]+/);
            if (length(fields) >= 2) mem_mb = int(fields[1]) / 1024;
            break;
        }
    }

    let status = last_ai_incident != null && (now - last_ai_incident.timestamp < 300) ? "repaired" : "healthy";

    let result = {
        status: status,
        ai_active: true,
        uptime_s: sb_uptime,
        memory_mb: mem_mb,
        proxy_ok: proxy_ok,
        proxy_latency_ms: average_latency(proxy_latency_history()),
        proxy_consecutive_fails: proxy_fails,
        dns_ok: dns_ok,
        dns_latency_ms: average_latency(dns_latency_history()),
        dns_consecutive_fails: dns_fails,
        incidents_total: ai_incidents_count,
        last_incident: last_ai_incident,
        healthy_streak: controller.healthy_streak(),
        adaptive_interval_s: adaptive_normal_interval(),
        reconnects_hour: int(trim(fs.readfile("/tmp/tachyon_reconnect_count") || "0"))
    };

    print(sprintf("%J\n", result));
}

let mode = (ARGV[0] == "") ? ARGV[1] : ARGV[0];
if (!mode) mode = "";

if (mode == "start-runtime")
    exit(start_runtime());
else if (mode == "stop-runtime")
    exit(stop_runtime());
else if (mode == "worker")
    exit(worker());
else if (mode == "status")
    exit(get_status());
else if (mode == "ai-heal") {
    ai_full_health_audit();
    print_ai_status();
    exit(0);
}
else if (mode == "ai-status") {
    print_ai_status();
    exit(0);
}
else if (mode == "ai-status-full") {
    print_ai_status_full();
    exit(0);
}
else if (mode == "smart-detect-extract-domain") {
    let extracted = smart_detect_extract_domain(ARGV[1]);
    if (extracted == null) exit(1);
    print(extracted + "\n");
    exit(0);
}
else {
    warn("Usage: service/watchdog.uc <start-runtime|stop-runtime|worker|status|ai-heal|ai-status|ai-status-full|smart-detect-extract-domain> ...\n");
    exit(1);
}
