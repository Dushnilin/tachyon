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

function parse_json_or_null(str) {
    try {
        return json(str);
    }
    catch (e) {
        return null;
    }
}

function now_seconds() {
    return int(clock()[0]);
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

    // Stop P2P Server
    let p2p_pid = trim(fs.readfile("/var/run/tachyon_p2p_server.pid") || "");
    if (process_running(p2p_pid)) {
        command_success_from_args([ "kill", p2p_pid ]);
    }
    remove_file("/var/run/tachyon_p2p_server.pid");

    return 0;
}

function start_runtime() {
    let cfg = settings();
    stop_runtime();

    let enable_watchdog = cfg.enable_watchdog != "0";
    if (!enable_watchdog && cfg.enable_p2p_sync != "1") {
        return 0;
    }

    let command = command_from_args([ "ucode", "-L", LIB_DIR, WATCHDOG_UC, "worker" ]) +
        " </dev/null >/dev/null 2>&1 1000<&- & echo $! >" + shell_quote(PID_FILE);
    return command_status(command);
}

function encrypt_p2p(data, token) {
    let payload_path = "/tmp/p2p_plain.json";
    let enc_path = "/tmp/p2p_enc.txt";
    fs.writefile(payload_path, data);
    system("openssl enc -aes-256-cbc -salt -pbkdf2 -pass pass:" + shell_quote(token) + " -in " + payload_path + " -out " + enc_path + " -base64 >/dev/null 2>&1");
    let result = trim(fs.readfile(enc_path) || "");
    remove_file(payload_path);
    remove_file(enc_path);
    return result;
}

function decrypt_p2p(enc_str, token) {
    let enc_path = "/tmp/p2p_enc.txt";
    let plain_path = "/tmp/p2p_plain.json";
    fs.writefile(enc_path, enc_str);
    let status = system("openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:" + shell_quote(token) + " -in " + enc_path + " -out " + plain_path + " -base64 >/dev/null 2>&1");
    let result = null;
    if (status == 0) {
        result = fs.readfile(plain_path);
    }
    remove_file(enc_path);
    remove_file(plain_path);
    return result;
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

function push_config_to_peers() {
    let cfg = settings();
    if (cfg.enable_p2p_sync != "1" || !cfg.p2p_sync_token) return;

    let peers_str = cfg.p2p_peers || "";
    let peers = split(trim(peers_str), /[ \t\r\n]+/);
    if (length(peers) == 0 || peers[0] == "") return;

    let config_data = fs.readfile("/etc/config/tachyon") || "";
    let hostname = trim(command_output_from_args(["hostname"]) || "router");

    let payload = {
        timestamp: now_seconds(),
        config: config_data,
        sender: hostname
    };

    let json_bytes = sprintf("%J", payload);
    let enc_payload = encrypt_p2p(json_bytes, cfg.p2p_sync_token);
    if (!enc_payload || enc_payload == "") return;

    log_message("P2P Sync: sending config to " + length(peers) + " peers...", "info");
    for (let peer in peers) {
        peer = trim(peer);
        if (peer == "") continue;
        if (index(peer, ":") < 0) {
            peer = peer + ":4536";
        }
        let url = "http://" + peer + "/sync";
        system("curl -s -X POST -H 'Content-Type: text/plain' --data-binary " + shell_quote(enc_payload) + " --max-time 5 " + url + " </dev/null >/dev/null 2>&1 1000<&- &");
    }
}

function p2p_receive() {
    let input = fs.open("/dev/stdin", "r");
    if (!input) return 0;
    let enc_payload = trim(input.read("all") || "");
    input.close();

    if (enc_payload == "") return 0;

    let cfg = settings();
    if (cfg.enable_p2p_sync != "1" || !cfg.p2p_sync_token) return 0;

    let decrypted = decrypt_p2p(enc_payload, cfg.p2p_sync_token);
    if (!decrypted) return 0;

    let payload = parse_json_or_null(decrypted);
    if (!payload || !payload.config || !payload.timestamp) return 0;

    let local_stat = fs.stat("/etc/config/tachyon");
    if (local_stat) {
        if (payload.timestamp <= local_stat.mtime) {
            return 0;
        }
        let local_content = fs.readfile("/etc/config/tachyon") || "";
        if (local_content == payload.config) {
            return 0;
        }
    }

    log_message("P2P Sync: received newer configuration from peer '" + (payload.sender || "unknown") + "'. Applying...", "info");
    fs.writefile("/etc/config/tachyon", payload.config);
    system("/usr/bin/tachyon restart >/dev/null 2>&1");
    return 0;
}

function worker() {
    log_message("Watchdog daemon started.", "info");

    system("mkfifo /tmp/tachyon_honeypot.fifo >/dev/null 2>&1");
    system("chmod 0666 /tmp/tachyon_honeypot.fifo >/dev/null 2>&1");

    let cfg = settings();
    let ttl = cfg.honeypot_ttl || "86400";
    let nft_table = getenv("NFT_TABLE_NAME") || "TachyonTable";

    system("tail -f /tmp/tachyon_honeypot.fifo | while read ip; do " +
           "if [ -n \"$ip\" ]; then " +
           "nft add element inet " + nft_table + " tachyon_honeypot { \"$ip\" timeout " + ttl + "s } >/dev/null 2>&1; " +
           "fi; done </dev/null >/dev/null 2>&1 1000<&- & echo $! > /var/run/tachyon_honeypot_listener.pid");

    let enable_p2p = cfg.enable_p2p_sync == "1";
    if (enable_p2p) {
        system("while true; do nc -l -p 4536 | ucode -L " + LIB_DIR + " " + WATCHDOG_UC + " p2p-receive; done </dev/null >/dev/null 2>&1 1000<&- & echo $! > /var/run/tachyon_p2p_server.pid");
    }

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
else if (mode == "p2p-receive")
    exit(p2p_receive());
else if (mode == "push-config")
    exit(push_config_to_peers());
else {
    warn("Usage: service/watchdog.uc <start-runtime|stop-runtime|worker|status|p2p-receive|push-config> ...\n");
    exit(1);
}
