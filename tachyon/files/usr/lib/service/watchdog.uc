#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");
let common = require("core.common");

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
        command_success_from_args([ "kill", "-9", pid ]);
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

function smart_detect_run(last_time) {
    let cfg = settings();
    if (cfg.smart_detect != "1") return last_time;
    let now = time();
    if (now - last_time < 60) return last_time;

    let seen = {};
    let seen_data = fs.readfile(SMART_DETECT_SEEN_FILE);
    if (seen_data) {
        try { seen = json(seen_data) || {}; } catch(e) {}
    }

    // Parse recent sing-box log lines for direct dial failures
    let log_out = command_output_from_args(["logread", "-l", "150"]) || "";
    let domains_to_check = {};
    for (let line in split(log_out, "\n")) {
        let ll = lc(line);
        if (index(ll, "direct") < 0 && index(ll, "DIRECT") < 0) continue;
        if (index(ll, "failed") < 0 && index(ll, "timeout") < 0 && index(ll, "reset") < 0) continue;
        // Extract quoted hostname like "twitch.tv:443"
        let m = match(line, /"([a-zA-Z0-9][a-zA-Z0-9.-]{1,60}\.[a-zA-Z]{2,})(:[0-9]+)?"/);
        if (!m) m = match(line, /target[= ]([a-zA-Z0-9][a-zA-Z0-9.-]{1,60}\.[a-zA-Z]{2,})/);
        if (!m) continue;
        let domain = m[1];
        if (!domain || length(domain) < 5) continue;
        if (seen[domain]) continue;
        domains_to_check[domain] = true;
    }

    let domain_list = keys(domains_to_check);
    if (length(domain_list) == 0) {
        return now;
    }

    let sections = smart_detect_get_proxy_sections();
    if (length(sections) == 0) return now;

    // Determine proxy address
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

    // Build ordered test list: smart_detect_sections UCI list → fallback to proxy sections
    let detect_sections = [];
    let raw_list = cfg.smart_detect_sections;
    if (type(raw_list) == "array") {
        detect_sections = raw_list;
    } else if (raw_list && trim(as_string(raw_list)) != "") {
        detect_sections = [ trim(as_string(raw_list)) ];
    }
    if (length(detect_sections) == 0) {
        detect_sections = sections; // fallback: all proxy sections in UCI order
    }

    for (let domain in domain_list) {
        seen[domain] = now;
        // Verify it actually fails directly
        let direct_ok = command_success_from_args([
            "curl", "-s", "-I", "--connect-timeout", "4", "--max-time", "6",
            "https://" + domain
        ]);
        if (direct_ok) continue;

        // Try each section in priority order
        let added = false;
        for (let sec_name in detect_sections) {
            sec_name = trim(as_string(sec_name));
            if (sec_name == "") continue;

            // Try via this section's proxy (we test with global proxy address first)
            let proxy_ok = command_success_from_args([
                "curl", "-s", "-I", "--connect-timeout", "5", "--max-time", "8",
                "--proxy", "http://" + proxy_addr,
                "https://" + domain
            ]);
            if (!proxy_ok) continue;

            // Works through proxy — add to this section
            log_message("Smart Detect: adding " + domain + " to section " + sec_name, "info");
            if (smart_detect_add_domain(sec_name, domain)) {
                let tcfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
                if (tcfg.enabled == "1" && tcfg.bot_token && tcfg.admin_ids) {
                    send_telegram_notification(
                        "\ud83d\udd0d *Smart Detect*: `" + domain + "` \u043d\u0435\u0434\u043e\u0441\u0442\u0443\u043f\u0435\u043d \u043d\u0430\u043f\u0440\u044f\u043c\u0443\u044e, \u0440\u0430\u0431\u043e\u0442\u0430\u0435\u0442 \u0447\u0435\u0440\u0435\u0437 \u043f\u0440\u043e\u043a\u0441\u0438.\n\u0414\u043e\u0431\u0430\u0432\u043b\u0435\u043d \u0432 \u0441\u0435\u043a\u0446\u0438\u044e *" + sec_name + "*."
                    );
                }
                added = true;
                break; // domain handled, move to next
            }
        }
        if (!added) {
            log_message("Smart Detect: domain " + domain + " not handled by any section", "info");
        }
    }

    // Prune seen cache (keep only last 24h)
    let clean = {};
    let cutoff = now - 86400;
    for (let k in keys(seen)) {
        if (seen[k] >= cutoff) clean[k] = seen[k];
    }
    fs.writefile(SMART_DETECT_SEEN_FILE, sprintf("%J", clean));
    return now;
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

    command_success_from_args(["sh", "-c", "kill -9 $(pgrep -f 'tail -f /tmp/tachyon_honeypot.fifo') 2>/dev/null"]);

    system("tail -f /tmp/tachyon_honeypot.fifo | while read ip; do " +
           "if [ -n \"$ip\" ]; then " +
           "nft add element inet " + nft_table + " tachyon_honeypot { \"$ip\" timeout " + ttl + "s } >/dev/null 2>&1; " +
           "fi; done </dev/null >/dev/null 2>&1 1000<&- & echo $! > /var/run/tachyon_honeypot_listener.pid");

    let zero_rtt_done = false;
    let smart_detect_last_run = 0;

    while (true) {
        cfg = settings();
        if (cfg.recovery_bypass == "1") {
            sleep(10000);
            continue;
        }

        // 0. Check pause file — skip health checks if proxy is intentionally paused
        if (check_auto_resume_pause()) {
            sleep(10000);
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
        
        let list_update_pid = trim(fs.readfile("/var/run/tachyon_list_update.pid") || "");
        let list_update_running = process_running(list_update_pid);

        let tachyon_cli_running = false;
        let tachyon_cli_pids = split(trim(command_output_from_args(["pgrep", "-f", "/usr/bin/tachyon "])), /\s+/);
        for (let cli_pid in tachyon_cli_pids) {
            if (cli_pid == "") continue;
            let cmdline = trim(command_output_from_args(["cat", "/proc/" + cli_pid + "/cmdline"]) || "");
            if (index(cmdline, "start") >= 0 || index(cmdline, "restart") >= 0 || index(cmdline, "reload") >= 0 || index(cmdline, "stop") >= 0) {
                tachyon_cli_running = true;
                break;
            }
        }

        if (tachyon_cli_running) {
            sleep(10000);
            continue;
        }

        if (pid == "" && has_sections && !list_update_running) {
            log_message("sing-box is stopped. Restarting Tachyon...", "warn");
            let tcfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
            if (tcfg.notify_crash != "0") {
                send_telegram_notification("⚠️ *Watchdog:* sing-box остановлен. Перезапускаю службы Tachyon...");
            }
            system("/etc/init.d/tachyon restart </dev/null >/dev/null 2>&1 &");
            sleep(60000);
            continue;
        }

        // 2. Firewall / NFT Check
        let routing_mode = cfg.routing_mode || "nftables";
        if (routing_mode == "nftables" && !list_update_running) {
            let out_nft = command_output_from_args(["nft", "list", "table", "inet", nft_table]);
            if (index(out_nft, "tproxy") < 0) {
                log_message("nftables rules are missing or corrupted. Rebuilding...", "warn");
                let tcfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
                if (tcfg.notify_crash != "0") {
                    send_telegram_notification("⚠️ *Watchdog:* правила nftables повреждены или отсутствуют. Выполняю пересборку...");
                }
                system("/etc/init.d/tachyon restart </dev/null >/dev/null 2>&1 &");
                sleep(60000);
                continue;
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

        // 5. Smart Detect — self-healing routing
        smart_detect_last_run = smart_detect_run(smart_detect_last_run);

        // 6. URLTest Proxy Switch Alerts
        let tcfg = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
        if (tcfg.enabled == "1" && tcfg.notify_crash != "0") {
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

        sleep(15000);
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
