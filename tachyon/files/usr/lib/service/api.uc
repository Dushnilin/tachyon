let fs = require("fs");
let uci_core = require("core.uci");
let common = require("core.common");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const PAUSE_FILE = "/tmp/tachyon_paused_until";
const WATCHDOG_PID_FILE = "/var/run/tachyon_watchdog.pid";

let as_string = common.as_string;
let command_capture = common.command_capture;
let command_success_from_args = common.command_success_from_args;
let command_from_args = common.command_from_args;

// Helper to get clash url
function get_clash_url(endpoint) {
    let host = "127.0.0.1:9090"; // default fallback
    let config_data = fs.readfile("/etc/sing-box/config.json");
    if (config_data) {
        try {
            let sb_cfg = json(config_data);
            let ext = sb_cfg.experimental?.clash_api?.external_controller;
            if (ext) {
                let parts = split(ext, ":");
                let ip = (length(parts) > 1) ? parts[0] : "";
                let port = (length(parts) > 1) ? parts[length(parts) - 1] : "9090";
                if (ip == "0.0.0.0" || ip == "") {
                    host = "127.0.0.1:" + port;
                } else {
                    host = ext;
                }
            }
        } catch(e) {}
    }
    return "http://" + host + "/" + endpoint;
}

// ─── API Functions ───────────────────────────────────────────────────────────

export function get_pause_remaining() {
    let val = trim(fs.readfile(PAUSE_FILE) || "");
    if (val == "") return 0;
    let until = int(val);
    let now = time();
    if (until <= now) return 0;
    return until - now;
}

export function process_running_by_pidfile(pidfile) {
    let pid = trim(fs.readfile(pidfile) || "");
    return pid != "" && match(pid, /^[0-9]+$/) != null &&
           command_success_from_args(["kill", "-0", pid]);
}

export function get_system_status() {
    let status_obj = {};

    // CPU
    let stat = fs.readfile("/proc/loadavg") || "";
    let load = split(stat, / /);
    status_obj.cpu = (length(load) > 0) ? load[0] : "unknown";

    // RAM
    let mem = fs.readfile("/proc/meminfo") || "";
    let total_kb = 0, avail_kb = 0;
    for (let line in split(mem, "\n")) {
        if (index(line, "MemTotal:") == 0) {
            total_kb = int(split(trim(line), /[ \t]+/)[1]);
        } else if (index(line, "MemAvailable:") == 0) {
            avail_kb = int(split(trim(line), /[ \t]+/)[1]);
        }
    }
    status_obj.ram_total = total_kb ? int(total_kb / 1024) : 0;
    status_obj.ram_avail = avail_kb ? int(avail_kb / 1024) : 0;

    // Uptime
    let upt = fs.readfile("/proc/uptime") || "";
    let up_sec = double(split(upt, / /)[0] || 0);
    let d = int(up_sec / 86400);
    let h = int((up_sec - (d * 86400)) / 3600);
    let m = int((up_sec - (d * 86400) - (h * 3600)) / 60);
    status_obj.uptime = sprintf("%d дн. %02d:%02d", d, h, m);

    // sing-box status
    let sb_running = command_success_from_args(["pidof", "sing-box"]);
    status_obj.singbox_running = sb_running;
    status_obj.singbox = sb_running ? "🟢 running" : "🔴 stopped";
    status_obj.tachyon_running = command_success_from_args(["/etc/init.d/tachyon", "status"]);

    // Active server + latency from Clash API
    status_obj.active_server = "";
    status_obj.latency = "";
    status_obj.active_tag = "";
    
    let pdata = get_clash_proxies_data();
    if (pdata && pdata.proxies) {
        let main_out = pdata.proxies["main-out"];
        if (main_out && main_out.now) {
            status_obj.active_server = main_out.now;
            status_obj.active_tag = "main-out"; // Or derive from actual proxy tag
            let srv = pdata.proxies[main_out.now];
            if (srv && type(srv.history) == "array" && length(srv.history) > 0) {
                let last = srv.history[length(srv.history) - 1];
                if (last && last.delay) {
                    status_obj.latency = last.delay; // int
                }
            }
        }
    }

    // Watchdog status
    status_obj.watchdog_running = process_running_by_pidfile(WATCHDOG_PID_FILE);

    // Pause state
    status_obj.pause_remaining = get_pause_remaining();

    // IPs
    status_obj.lan_ip = as_string(common.command_output("uci -q get network.lan.ipaddr"));
    status_obj.wan_ip = as_string(common.command_output("ip route get 8.8.8.8 2>/dev/null | grep -Eo 'src [0-9.]+' | awk '{print $2}'"));
    
    // Tachyon Version
    let opkg_out = common.command_output("opkg status tachyon 2>/dev/null | grep Version");
    status_obj.tachyon_version = split(trim(opkg_out), " ")[1] || "unknown";

    return status_obj;
}

export function get_clash_proxies_data() {
    let args = [ "curl", "-s", get_clash_url("proxies") ];
    let res = command_capture(command_from_args(args));
    if (res.status == 0 && res.output != "") {
        try {
            return json(res.output);
        } catch (e) {}
    }
    return null;
}

export function clash_request(method, endpoint, payload) {
    let url = get_clash_url(endpoint);
    let payload_path = "/tmp/clash_payload_" + method + "_" + time() + "_" + clock()[1] + ".json";
    let res = null;
    try {
        let args = [ "curl", "-s", "-X", method ];
        if (payload) {
            fs.writefile(payload_path, sprintf("%J", payload));
            push(args, "-H", "Content-Type: application/json", "-d", "@" + payload_path);
        }
        push(args, url);
        res = command_capture(command_from_args(args));
    }
    catch (e) {
        if (payload) {
            try { fs.unlink(payload_path); } catch(err) {}
        }
        return null;
    }
    
    if (payload) {
        try { fs.unlink(payload_path); } catch(err) {}
    }
    
    if (!res || res.status != 0 || res.output == "") {
        return null;
    }
    
    try {
        return json(res.output);
    }
    catch (e) {
        return res.output;
    }
}

export function get_clash_connections() {
    let args = [ "curl", "-s", get_clash_url("connections") ];
    let res = command_capture(command_from_args(args));
    if (res.status == 0 && res.output != "") {
        try {
            return json(res.output);
        } catch (e) {}
    }
    return null;
}

export function check_connection() {
    let res_direct = command_capture("curl -I -s --connect-timeout 5 https://www.google.com");
    let direct_ok = (res_direct.status == 0) ? true : false;
    
    let res_proxy = command_capture("curl -I -s --connect-timeout 5 --proxy http://127.0.0.1:4534 https://www.google.com");
    let proxy_ok = (res_proxy.status == 0) ? true : false;
    
    return { direct: direct_ok, proxy: proxy_ok };
}

export function run_speedtest() {
    // Direct speedtest
    let res_direct = command_capture("curl -s -w '%{speed_download}' -o /dev/null --connect-timeout 8 https://speed.cloudflare.com/__down?bytes=5242880");
    let direct_speed = double(res_direct.output || 0);
    let direct_mbps = (direct_speed * 8) / 1000000;
    
    // Proxy speedtest
    let res_proxy = command_capture("curl -s -w '%{speed_download}' -o /dev/null --connect-timeout 8 --proxy http://127.0.0.1:4534 https://speed.cloudflare.com/__down?bytes=5242880");
    let proxy_speed = double(res_proxy.output || 0);
    let proxy_mbps = (proxy_speed * 8) / 1000000;
    
    return { direct_mbps: direct_mbps, proxy_mbps: proxy_mbps };
}

export function manage_domain_list(action_type, domain, do_delete) {
    let c = uci_core.cursor();
    if (!c) return { success: false, error: "Не удалось инициализировать UCI" };
    c.load(CONFIG_NAME);

    let target_section = null;
    c.foreach(CONFIG_NAME, "section", function(s) {
        if (s.enabled == "1" && s.action == action_type) {
            target_section = s[".name"];
            return false;
        }
    });

    if (!target_section) {
        return { success: false, error: "Не найдено активное правило с действием '" + action_type + "'." };
    }

    return manage_domain_list_by_section(target_section, domain, do_delete);
}

export function manage_domain_list_by_section(sec_name, domain, do_delete) {
    let c = uci_core.cursor();
    if (!c) return { success: false, error: "Не удалось инициализировать UCI" };
    c.load(CONFIG_NAME);

    let s = c.get_all(CONFIG_NAME, sec_name);
    if (!s) {
        return { success: false, error: "Секция '" + sec_name + "' не найдена." };
    }

    let option_path = CONFIG_NAME + "." + sec_name + ".domain";

    if (do_delete) {
        let deleted = uci_core.del_list(option_path, domain);
        if (deleted) {
            uci_core.commit(CONFIG_NAME);
            common.command_status("/usr/bin/tachyon reload");
            return { success: true, message: "Запись <code>" + domain + "</code> удалена." };
        } else {
            return { success: false, error: "Запись <code>" + domain + "</code> не найдена." };
        }
    } else {
        let current_val = uci_core.get(option_path);
        let exists = false;
        if (current_val != "") {
            for (let item in split(current_val, " ")) {
                if (item == domain) {
                    exists = true;
                    break;
                }
            }
        }
        if (exists) {
            return { success: false, error: "Запись <code>" + domain + "</code> уже есть в секции." };
        }

        let added = uci_core.add_list(option_path, domain);
        if (added) {
            uci_core.commit(CONFIG_NAME);
            common.command_status("/usr/bin/tachyon reload");
            return { success: true, message: "Запись <code>" + domain + "</code> добавлена." };
        }
        return { success: false, error: "Не удалось добавить запись." };
    }
}

export function get_sections() {
    let c = uci_core.cursor();
    if (!c) return [];
    c.load(CONFIG_NAME);
    
    let sections = [];
    c.foreach(CONFIG_NAME, "section", function(s) {
        push(sections, s);
    });
    return sections;
}

export function get_servers() {
    let c = uci_core.cursor();
    if (!c) return [];
    c.load(CONFIG_NAME);
    
    let servers = [];
    c.foreach(CONFIG_NAME, "server", function(s) {
        push(servers, s);
    });
    return servers;
}

export function reload_tachyon() {
    common.command_status("/usr/bin/tachyon reload");
    return true;
}

export function toggle_section(sec_name) {
    let c = uci_core.cursor();
    if (!c) return false;
    c.load(CONFIG_NAME);
    
    let s = c.get_all(CONFIG_NAME, sec_name);
    if (!s) return false;
    
    let new_val = (s.enabled == "1") ? "0" : "1";
    uci_core.set(CONFIG_NAME + "." + sec_name + ".enabled", new_val);
    uci_core.commit(CONFIG_NAME);
    reload_tachyon();
    return true;
}
