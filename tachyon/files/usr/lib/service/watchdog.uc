#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");
let common = require("core.common");
let helpers = require("core.helpers");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const PID_FILE = "/var/run/tachyon_watchdog.pid";
const WATCHDOG_UC = LIB_DIR + "/service/watchdog.uc";
const PAUSE_FILE = "/tmp/tachyon_paused_until";
const SMART_DETECT_SEEN_FILE = "/tmp/tachyon_smart_detect_seen.json";


let as_string = common.as_string;
let shell_quote = common.shell_quote;

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

function command_output(command) {
    let result = command_capture(command);
    return result.status == 0 ? result.output : "";
}

function command_output_from_args(args) {
    return command_output(command_from_args(args) + " 2>/dev/null");
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
    let secs = [];
    c.foreach(CONFIG_NAME, "section", function(s) {
        if (s.enabled != "1") return;
        let act = as_string(s.action || "");
        if (act == "proxy" || act == "connection" || act == "outbound" || act == "vpn") {
            push(secs, s[".name"]);
        }
    });
    return secs;
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

let last_oom_time = 0;
let last_restart_time = 0;
let last_urltest_check = 0;
let pending_smart_domains = {};
let smart_detect_last_run = 0;

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

function handle_singbox_stop_event(reason) {
    let now = time();
    if (now - last_restart_time < 30) return;
    last_restart_time = now;

    let cfg = settings();
    if (cfg.recovery_bypass == "1") return;
    if (check_auto_resume_pause()) return;
    if (check_tachyon_cli_running()) return;

    let list_update_pid = trim(fs.readfile("/var/run/tachyon_list_update.pid") || "");
    if (process_running(list_update_pid, "ucode")) return;

    log_message("sing-box is stopped (" + as_string(reason || "health check") + "). Restarting Tachyon...", "warn");
    let tcfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
    if (tcfg.notify_crash != "0") {
        send_telegram_notification("⚠️ *Watchdog:* sing-box остановлен. Перезапускаю службы Tachyon...");
    }
    system("/etc/init.d/tachyon restart </dev/null >/dev/null 2>&1 &");
}

function check_singbox_process() {
    let cfg = settings();
    if (cfg.recovery_bypass == "1") return;
    if (check_auto_resume_pause()) return;
    if (check_tachyon_cli_running()) return;

    let list_update_pid = trim(fs.readfile("/var/run/tachyon_list_update.pid") || "");
    if (process_running(list_update_pid, "ucode")) return;

    // Fast-path check: verify if sing-box PID file exists and process is active
    let sb_pid = trim(fs.readfile("/var/run/sing-box.pid") || "");
    if (sb_pid != "" && process_running(sb_pid, "sing-box")) {
        return;
    }

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

    let binary_name = "sing-box";
    let pid = "";
    let proc = fs.opendir("/proc");
    if (proc) {
        let entry;
        while ((entry = proc.read()) != null) {
            if (match(entry, /^[0-9]+$/)) {
                let exe = fs.readlink("/proc/" + entry + "/exe") || "";
                let slash = rindex(exe, "/");
                if ((slash >= 0 ? substr(exe, slash + 1) : exe) == binary_name) {
                    pid = entry;
                    break;
                }
            }
        }
        proc.close();
    }

    if (pid == "") {
        handle_singbox_stop_event("process missing from /proc");
    }
}

function check_firewall_rules() {
    let cfg = settings();
    let routing_mode = cfg.routing_mode || "nftables";
    let nft_table = getenv("NFT_TABLE_NAME") || "TachyonTable";

    let list_update_pid = trim(fs.readfile("/var/run/tachyon_list_update.pid") || "");
    if (process_running(list_update_pid, "ucode")) return;

    if (routing_mode == "nftables") {
        let out_nft = command_output_from_args(["nft", "list", "table", "inet", nft_table]);
        if (index(out_nft, "tproxy") < 0) {
            log_message("nftables rules are missing or corrupted. Rebuilding...", "warn");
            let tcfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
            if (tcfg.notify_crash != "0") {
                send_telegram_notification("⚠️ *Watchdog:* правила nftables повреждены или отсутствуют. Выполняю пересборку...");
            }
            system("/etc/init.d/tachyon restart </dev/null >/dev/null 2>&1 &");
        }
    }
}

function check_memory() {
    let free_mb = -1;
    let mem_info = fs.readfile("/proc/meminfo") || "";
    for (let line in split(mem_info, "\n")) {
        if (index(line, "MemAvailable:") == 0) {
            let fields = split(trim(line), /[ \t]+/);
            if (length(fields) >= 2) {
                free_mb = int(fields[1]) / 1024;
            }
            break;
        }
    }
    if (free_mb >= 0 && free_mb < 15) {
        log_message("Low memory detected (" + free_mb + "MB). Clearing caches...", "warn");
        system("echo 3 > /proc/sys/vm/drop_caches");
    }
}

function check_urltest_switches() {
    let now = time();
    if (now - last_urltest_check < 5) return;
    last_urltest_check = now;

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
                    let last_now = trim(fs.readfile("/tmp/watchdog_urltest_" + name) || "");
                    if (last_now != "" && last_now != p.now) {
                        send_telegram_notification("🔀 *Watchdog:* Смена прокси в группе `" + name + "`\nНовый активный узел: `" + p.now + "`");
                    }
                    fs.writefile("/tmp/watchdog_urltest_" + name, p.now);
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
    if (now - smart_detect_last_run < 60) return;

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
        seen[domain] = now;
        let direct_ok = command_success_from_args([
            "curl", "-s", "-I", "--connect-timeout", "4", "--max-time", "6",
            "https://" + domain
        ]);
        if (direct_ok) continue;

        let added = false;
        for (let sec_name in detect_sections) {
            sec_name = trim(as_string(sec_name));
            if (sec_name == "") continue;

            let proxy_ok = command_success_from_args([
                "curl", "-s", "-I", "--connect-timeout", "5", "--max-time", "8",
                "--proxy", "http://" + proxy_addr,
                "https://" + domain
            ]);
            if (!proxy_ok) continue;

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
    }

    let clean = {};
    let cutoff = now - 86400;
    for (let k in keys(seen)) {
        if (seen[k] >= cutoff) clean[k] = seen[k];
    }
    fs.writefile(SMART_DETECT_SEEN_FILE, sprintf("%J", clean));
}

function handle_log_line(line) {
    if (!line || line == "") return;

    // Fast keyword pre-filter: skip 95%+ of irrelevant log lines instantly
    if (index(line, "direct") < 0 && index(line, "DIRECT") < 0 &&
        index(line, "memory") < 0 && index(line, "oom") < 0 && index(line, "OOM") < 0 &&
        index(line, "URLTest") < 0 && index(line, "proxy") < 0) {
        return;
    }
    let line_lower = lc(line);

    // 1. OOM Detection
    if (index(line_lower, "out of memory") >= 0 || index(line_lower, "oom-killer") >= 0) {
        let now = time();
        if (now - last_oom_time > 30) {
            last_oom_time = now;
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
        return;
    }

    // 2. Smart Detect candidate domain extraction
    let cfg = settings();
    if (cfg.smart_detect == "1") {
        if ((index(line_lower, "direct") >= 0 || index(line_lower, "DIRECT") >= 0) &&
            (index(line_lower, "failed") >= 0 || index(line_lower, "timeout") >= 0 || index(line_lower, "reset") >= 0)) {
            let m = match(line, /"([a-zA-Z0-9][a-zA-Z0-9.-]{1,60}\.[a-zA-Z]{2,})(:[0-9]+)?"/);
            if (!m) m = match(line, /target[= ]([a-zA-Z0-9][a-zA-Z0-9.-]{1,60}\.[a-zA-Z]{2,})/);
            if (m && m[1] && length(m[1]) >= 5) {
                pending_smart_domains[m[1]] = time();
            }
        }
    }

    // 3. URLTest proxy switch notifications
    if (index(line, "URLTest") >= 0 || index(line_lower, "selected proxy") >= 0 || index(line_lower, "switch proxy") >= 0) {
        check_urltest_switches();
    }
}

function setup_honeypot_listener() {
    system("mkfifo /tmp/tachyon_honeypot.fifo >/dev/null 2>&1");
    system("chmod 0660 /tmp/tachyon_honeypot.fifo >/dev/null 2>&1");

    command_success_from_args(["sh", "-c", "kill -9 $(pgrep -f 'tail -f /tmp/tachyon_honeypot.fifo') 2>/dev/null"]);

    let fifo_fd = fs.open("/tmp/tachyon_honeypot.fifo", "r+");
    if (uloop && fifo_fd) {
        try {
            uloop.handle(fifo_fd.fileno(), function(events) {
                let line;
                while ((line = fifo_fd.read("line")) != null) {
                    let ip = trim(as_string(line));
                    if (ip != "" && match(ip, /^[0-9a-fA-F:.]+$/) != null) {
                        let cfg = settings();
                        let ttl = cfg.honeypot_ttl || "86400";
                        let nft_table = getenv("NFT_TABLE_NAME") || "TachyonTable";
                        command_success_from_args(["nft", "add", "element", "inet", nft_table, "tachyon_honeypot", "{", ip, "timeout", ttl + "s", "}"]);
                    }
                }
            }, uloop.ULOOP_READ);
        } catch (e) {
            log_message("Failed to bind honeypot fifo to uloop: " + as_string(e), "warn");
        }
    } else {
        let cfg = settings();
        let ttl = cfg.honeypot_ttl || "86400";
        let nft_table = getenv("NFT_TABLE_NAME") || "TachyonTable";
        system("tail -f /tmp/tachyon_honeypot.fifo | while read ip; do " +
               "if [ -n \"$ip\" ]; then " +
               "nft add element inet " + nft_table + " tachyon_honeypot { \"$ip\" timeout " + ttl + "s } >/dev/null 2>&1; " +
               "fi; done </dev/null >/dev/null 2>&1 1000<&- & echo $! > /var/run/tachyon_honeypot_listener.pid");
    }
}

function setup_syslog_listener() {
    if (!uloop) return null;
    let log_pipe = fs.popen("logread -f 2>/dev/null", "r");
    if (!log_pipe) return null;

    try {
        uloop.handle(log_pipe.fileno(), function(events) {
            let line;
            while ((line = log_pipe.read("line")) != null) {
                handle_log_line(trim(as_string(line)));
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
    if (!conn) return null;

    try {
        conn.listen({
            "service.instance.stop": function(ev, msg) {
                if (type(msg) == "object" && msg.name == "sing-box") {
                    handle_singbox_stop_event("ubus service.instance.stop event");
                }
            },
            "service.stop": function(ev, msg) {
                if (type(msg) == "object" && msg.name == "sing-box") {
                    handle_singbox_stop_event("ubus service.stop event");
                }
            },
            "firewall.reload": function(ev, msg) {
                check_firewall_rules();
            }
        });
    } catch (e) {
        log_message("Failed to register ubus listeners: " + as_string(e), "warn");
    }
    return conn;
}

function worker() {
    log_message("Watchdog daemon started.", "info");

    setup_honeypot_listener();
    run_zero_rtt_prefetching();

    if (uloop) {
        try {
            uloop.init();
        } catch (e) {
            log_message("Failed to initialize uloop: " + as_string(e), "warn");
        }
    }

    let log_pipe = setup_syslog_listener();
    let ubus_conn = setup_ubus_listener();

    function perform_periodic_checks() {
        check_auto_resume_pause();
        check_singbox_process();
        check_firewall_rules();
        check_memory();
        smart_detect_process_pending();
    }

    if (uloop) {
        let timer_cb;
        timer_cb = function() {
            try {
                perform_periodic_checks();
            } catch (e) {
                log_message("Error in periodic check: " + as_string(e), "err");
            }
            uloop.timer(120000, timer_cb);
        };
        uloop.timer(10000, timer_cb);

        log_message("Watchdog running in event-driven uloop mode.", "info");
        uloop.run();
    } else {
        log_message("uloop not available. Running Watchdog in legacy fallback loop mode.", "warn");
        while (true) {
            perform_periodic_checks();
            sleep(60000);
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
else {
    warn("Usage: service/watchdog.uc <start-runtime|stop-runtime|worker|status> ...\n");
    exit(1);
}
