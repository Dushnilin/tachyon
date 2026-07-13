#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");
let common = require("core.common");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const PID_FILE = "/var/run/tachyon_watchdog.pid";
const WATCHDOG_UC = LIB_DIR + "/service/watchdog.uc";

let as_string = common.as_string;
let shell_quote = common.shell_quote;

let command_from_args = common.command_from_args;
let command_status = common.command_status;
let command_success_from_args = common.command_success_from_args;
let command_output_from_args = common.command_output_from_args;

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
    command_success_from_args([ "logger", "-t", "tachyon", "[" + as_string(level || "info") + "] Watchdog: " + as_string(message) ]);
}

function send_telegram_notification(message) {
    let tcfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
    if (tcfg.enabled == "1" && tcfg.bot_token && tcfg.admin_ids) {
        system("/usr/bin/tachyon telegram send " + shell_quote(message) + " </dev/null >/dev/null 2>&1 1000<&- &");
    }
}

function process_running(pid) {
    return match(as_string(pid), /^[0-9]+$/) != null && command_success_from_args([ "kill", "-0", pid ]);
}

function stop_runtime() {
    let pid = trim(fs.readfile(PID_FILE) || "");
    if (process_running(pid)) {
        command_success_from_args([ "kill", pid ]);
    }
    remove_file(PID_FILE);

    // Stop Honeypot listener
    let hp_pid = trim(fs.readfile("/var/run/tachyon_honeypot_listener.pid") || "");
    if (process_running(hp_pid)) {
        command_success_from_args([ "kill", hp_pid ]);
    }
    remove_file("/var/run/tachyon_honeypot_listener.pid");
    remove_file("/tmp/tachyon_honeypot.fifo");

    return 0;
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

        // Collect custom domains
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

    log_message("Zero-RTT Prefetcher: pre-resolving " + length(domain_list) + " domains...", "info");
    for (let dom in domain_list) {
        system("dig @127.0.0.1 " + shell_quote(dom) + " A </dev/null >/dev/null 2>&1 1000<&- &");
    }
}

function worker() {
    log_message("Watchdog daemon started.", "info");

    system("mkfifo /tmp/tachyon_honeypot.fifo >/dev/null 2>&1");
    system("chmod 0660 /tmp/tachyon_honeypot.fifo >/dev/null 2>&1");

    let cfg = settings();
    let ttl = cfg.honeypot_ttl || "86400";
    let nft_table = getenv("NFT_TABLE_NAME") || "TachyonTable";

    system("tail -f /tmp/tachyon_honeypot.fifo | while read ip; do " +
           "if [ -n \"$ip\" ]; then " +
           "nft add element inet " + nft_table + " tachyon_honeypot { \"$ip\" timeout " + ttl + "s } >/dev/null 2>&1; " +
           "fi; done </dev/null >/dev/null 2>&1 1000<&- & echo $! > /var/run/tachyon_honeypot_listener.pid");

    let zero_rtt_done = false;

    while (true) {
        cfg = settings();
        if (cfg.recovery_bypass == "1") {
            sleep(10);
            continue;
        }

        // 1. Process Check
        let binary_name = "sing-box";
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

        let pids = split(trim(command_output_from_args(["pidof", binary_name])), /\s+/);
        let pid = (length(pids) > 0 && pids[0] != "") ? pids[0] : "";
        if (pid == "" && has_sections) {
            log_message("sing-box is stopped. Restarting Tachyon...", "warn");
            let tcfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
            if (tcfg.notify_crash != "0") {
                send_telegram_notification("⚠️ *Watchdog:* sing-box остановлен. Перезапускаю службы Tachyon...");
            }
            command_status("/usr/bin/tachyon restart >/dev/null 2>&1");
        }

        // 2. Firewall / NFT Check
        let routing_mode = cfg.routing_mode || "nftables";
        if (routing_mode == "nftables") {
            let out_nft = command_output_from_args(["nft", "list", "table", "inet", nft_table]);
            if (index(out_nft, "tproxy") < 0) {
                log_message("nftables rules are missing or corrupted. Rebuilding...", "warn");
                let tcfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
                if (tcfg.notify_crash != "0") {
                    send_telegram_notification("⚠️ *Watchdog:* правила nftables повреждены или отсутствуют. Выполняю пересборку...");
                }
                command_status("/usr/bin/tachyon restart >/dev/null 2>&1");
            }
        }

        // 3. Memory & OOM Mitigation
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

        let logread_out = command_output_from_args(["logread", "-l", "100"]);
        let logread_lower = lc(logread_out);
        if (index(logread_lower, "out of memory") >= 0 || index(logread_lower, "oom-killer") >= 0) {
            log_message("OOM event detected! Reducing GOMEMLIMIT scaling...", "err");
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

        // 4. Zero-RTT Prefetching
        if (!zero_rtt_done) {
            run_zero_rtt_prefetching();
            zero_rtt_done = true;
        }

        sleep(15);
    }
}

function get_status() {
    let pid = trim(fs.readfile(PID_FILE) || "");
    if (process_running(pid)) {
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
