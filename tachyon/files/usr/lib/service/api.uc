let fs = require("fs");
let uci_core = require("core.uci");
let common = require("core.common");
let constants = require("core.constants");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const PAUSE_FILE = "/tmp/tachyon_paused_until";
const WATCHDOG_PID_FILE = "/var/run/tachyon_watchdog.pid";

let as_string = common.as_string;
let command_capture = common.command_capture;
let command_success_from_args = common.command_success_from_args;
let core_binary_running = common.core_binary_running;
let command_from_args = common.command_from_args;
let command_output = common.command_output;

function read_active_core_config() {
    let cfg_path = uci_core.get(CONFIG_NAME, "settings", "config_path");
    if (cfg_path && cfg_path != "") {
        let d = fs.readfile(cfg_path);
        if (d) return d;
    }
    return fs.readfile("/etc/tachyon-core/config.json") || fs.readfile("/etc/sing-box/config.json");
}

// Helper to get clash url
function get_clash_url(endpoint) {
    let host = "127.0.0.1:9090"; // default fallback
    let config_data = read_active_core_config();
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
        }
        catch (e) {
            // Falls through to the default host below. The clash API is optional
            // and every caller already treats an unreachable one as "no data".
        }
    }
    return "http://" + host + "/" + endpoint;
}

function get_clash_secret() {
    let config_data = read_active_core_config();
    if (config_data) {
        try {
            let sb_cfg = json(config_data);
            let secret = sb_cfg.experimental?.clash_api?.secret;
            if (secret && secret != "")
                return secret;
        }
        catch (e) {}
    }
    let uci_secret = uci_core.get(CONFIG_NAME, "settings", "yacd_secret_key");
    if (uci_secret && uci_secret != "")
        return uci_secret;
    return "";
}

function get_clash_auth_args() {
    let secret = get_clash_secret();
    if (secret != "")
        return [ "-H", "Authorization: Bearer " + secret ];
    return [];
}


// ─── API Functions ───────────────────────────────────────────────────────────

function get_pause_remaining() {
    let val = trim(fs.readfile(PAUSE_FILE) || "");
    if (val == "") return 0;
    let until = int(val);
    let now = time();
    if (until <= now) return 0;
    return until - now;
}

function process_running_by_pidfile(pidfile) {
    let pid = trim(fs.readfile(pidfile) || "");
    return pid != "" && match(pid, /^[0-9]+$/) != null &&
           command_success_from_args(["kill", "-0", pid]);
}

function country_code_to_flag(cc) {
    cc = uc(trim(as_string(cc || "")));
    if (length(cc) != 2)
        return "";
    let c0 = ord(cc, 0);
    let c1 = ord(cc, 1);
    if (c0 < 65 || c0 > 90 || c1 < 65 || c1 > 90)
        return "";
    // UTF-8 Regional Indicator Symbols: U+1F1E6 ('A') .. U+1F1FF ('Z')
    // U+1F1E6 in UTF-8 is 0xF0 0x9F 0x87 (0xA6 + offset)
    return chr(0xF0, 0x9F, 0x87, 0xA6 + (c0 - 65), 0xF0, 0x9F, 0x87, 0xA6 + (c1 - 65));
}

function get_outbound_display_metadata() {
    let meta = {
        names: {},
        countries: {},
        protocols: {},
        details: {},
        section_labels: {},
        group_labels: {}
    };

    try {
        let c = uci_core.cursor();
        if (c) {
            c.load(CONFIG_NAME);
            c.foreach(CONFIG_NAME, "section", function(s) {
                let sname = as_string(s[".name"] || "");
                if (sname == "") return;
                let slabel = trim(as_string(s.label || s.name || sname));
                meta.section_labels[sname] = slabel;
                meta.group_labels[sname + "-out"] = slabel;
                meta.group_labels[uc(sname) + "-out"] = slabel;
            });
            c.foreach(CONFIG_NAME, "balancer", function(b) {
                let bname = as_string(b[".name"] || "");
                if (bname == "") return;
                let blabel = trim(as_string(b.label || b.name || bname));
                meta.group_labels[bname] = blabel;
                meta.group_labels[bname + "-out"] = blabel;
            });
        }
    } catch (e) {}

    let cache_dir = getenv("TACHYON_SECTION_CACHE_DIR") || "/var/run/tachyon/section-cache";
    for (let path in (fs.glob(cache_dir + "/*.json") || [])) {
        let cache = common.read_json_file(path);
        if (type(cache) != "object")
            continue;
        let sec_name = as_string(cache.section || "");
        let om = common.object_or_empty(cache.outboundMetadata);
        let names = common.object_or_empty(om.names);
        let countries = common.object_or_empty(om.countries);
        let protocols = common.object_or_empty(om.protocols);
        let details = common.object_or_empty(om.details);
        for (let tag, dname in names) {
            if (as_string(dname) != "")
                meta.names[tag] = as_string(dname);
        }
        for (let tag, cc in countries) {
            if (as_string(cc) != "")
                meta.countries[tag] = as_string(cc);
        }
        for (let tag, proto in protocols) {
            if (as_string(proto) != "")
                meta.protocols[tag] = as_string(proto);
        }
        for (let tag, det in details) {
            if (as_string(det) != "")
                meta.details[tag] = as_string(det);
        }
        let ug = common.object_or_empty(cache.urltestGroups);
        for (let gtag, ginfo in ug) {
            if (type(ginfo) == "object" && as_string(ginfo.displayName || "") != "")
                meta.group_labels[gtag] = as_string(ginfo.displayName);
        }
        if (sec_name != "" && meta.section_labels[sec_name]) {
            meta.group_labels[sec_name + "-out"] = meta.section_labels[sec_name];
        }
    }

    return meta;
}

function format_outbound_display_name(tag, meta) {
    tag = as_string(tag || "");
    if (tag == "")
        return "";
    if (!meta)
        meta = get_outbound_display_metadata();
    let dname = as_string((meta.names && meta.names[tag]) || (meta.group_labels && meta.group_labels[tag]) || tag);
    let cc = as_string((meta.countries && meta.countries[tag]) || "");
    let flag = country_code_to_flag(cc);
    if (flag != "" && index(dname, flag) < 0)
        dname = flag + " " + dname;
    return dname;
}

function format_group_display_name(group_tag, meta) {
    group_tag = as_string(group_tag || "");
    if (group_tag == "")
        return "";
    if (!meta)
        meta = get_outbound_display_metadata();
    let base = replace(group_tag, /-out$/, "");
    let label = (meta.group_labels && (meta.group_labels[group_tag] || meta.group_labels[base])) ||
                (meta.section_labels && meta.section_labels[base]) || "";
    if (label != "" && label != group_tag && label != base)
        return label + " (" + group_tag + ")";
    return group_tag;
}

function url_encode_component(str) {
    str = as_string(str || "");
    let out = "";
    for (let i = 0; i < length(str); i++) {
        let ch = substr(str, i, 1);
        let code = ord(ch, 0);
        if ((code >= 48 && code <= 57) ||
            (code >= 65 && code <= 90) ||
            (code >= 97 && code <= 122) ||
            ch == "-" || ch == "_" || ch == "." || ch == "~") {
            out += ch;
        } else {
            out += sprintf("%%%02X", code);
        }
    }
    return out;
}

function get_clash_proxies_data() {
    let args = [ "curl", "-s", "-m", "5", "--connect-timeout", "3" ];
    for (let h in get_clash_auth_args()) push(args, h);
    push(args, get_clash_url("proxies"));
    let res = command_capture(command_from_args(args));
    if (res && res.status == 0 && res.output != "") {
        try {
            return json(res.output);
        } catch (e) {
            warn("api: failed to parse proxies JSON: " + as_string(e) + "\n");
        }
    }
    return null;
}

function probe_group_delay(group_name, timeout_ms) {
    group_name = as_string(group_name || "");
    if (group_name == "")
        return null;
    timeout_ms = int(timeout_ms || 3000);
    if (timeout_ms < 500) timeout_ms = 3000;
    let encoded_group = url_encode_component(group_name);
    let endpoint = "group/" + encoded_group + "/delay?url=" +
        url_encode_component("https://www.gstatic.com/generate_204") +
        "&timeout=" + as_string(timeout_ms);
    let args = [ "curl", "-s", "-m", "8", "--connect-timeout", "3" ];
    for (let h in get_clash_auth_args()) push(args, h);
    push(args, get_clash_url(endpoint));
    let res = command_capture(command_from_args(args));
    if (res && res.status == 0 && res.output != "") {
        try { return json(res.output); } catch (e) {}
    }
    return null;
}

function probe_all_groups_delay(timeout_ms) {
    let data = get_clash_proxies_data();
    if (!data || !data.proxies)
        return false;
    let probed = 0;
    for (let gname in keys(data.proxies)) {
        let p = data.proxies[gname];
        if (p && (p.type == "Selector" || p.type == "URLTest" || p.type == "Fallback")) {
            probe_group_delay(gname, timeout_ms);
            probed++;
        }
    }
    return probed > 0;
}

function get_system_status() {
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

    // Routing engine status
    let engine_name = "tachyon-core";
    try { engine_name = require("core.engine").get_active(); } catch (e) {}
    status_obj.engine_name = engine_name;
    let sb_running = core_binary_running();
    status_obj.singbox_running = sb_running;
    status_obj.singbox = sb_running ? "🟢 running" : "🔴 stopped";
    if (engine_name == "sing-box") {
        let sb_variant = trim(as_string(fs.readfile("/etc/tachyon/sing-box-variant") || fs.readfile("/etc/tachyon/tachyon-core-variant") || ""));
        if (sb_variant != "" && sb_variant != "tachyon-core")
            status_obj.singbox_variant = sb_variant;
    }

    // zapret2 / zapret / byedpi / wdtt / olcrtc status
    let z2_installed = fs.stat("/opt/zapret2/nfq2/nfqws2") != null ||
                       fs.stat("/opt/zapret2/nfq/nfqws2") != null ||
                       fs.stat("/opt/zapret2/nfqws2") != null ||
                       fs.stat("/usr/bin/nfqws2") != null;
    status_obj.zapret2_installed = z2_installed;
    if (z2_installed) {
        let z2_running = command_success_from_args(["pidof", "nfqws2"]);
        status_obj.zapret2_running = z2_running;
        status_obj.zapret2 = z2_running ? "🟢 running" : "🔴 stopped";
    }

    let z1_installed = fs.stat("/opt/zapret/nfq/nfqws") != null ||
                       fs.stat("/usr/bin/nfqws") != null;
    status_obj.zapret_installed = z1_installed;
    if (z1_installed) {
        let z1_running = command_success_from_args(["pidof", "nfqws"]);
        status_obj.zapret_running = z1_running;
        status_obj.zapret = z1_running ? "🟢 running" : "🔴 stopped";
    }

    let bd_installed = fs.stat("/usr/bin/ciadpi") != null || fs.stat("/usr/sbin/ciadpi") != null;
    status_obj.byedpi_installed = bd_installed;
    if (bd_installed) {
        let bd_running = command_success_from_args(["pidof", "ciadpi"]);
        status_obj.byedpi_running = bd_running;
        status_obj.byedpi = bd_running ? "🟢 running" : "🔴 stopped";
    }

    let wdtt_installed = fs.stat("/usr/bin/wdtt") != null || fs.stat("/usr/sbin/wdtt") != null;
    status_obj.wdtt_installed = wdtt_installed;
    if (wdtt_installed) {
        let wdtt_running = command_success_from_args(["pidof", "wdtt"]);
        status_obj.wdtt_running = wdtt_running;
        status_obj.wdtt = wdtt_running ? "🟢 running" : "🔴 stopped";
    }

    let olc_installed = fs.stat("/usr/bin/olcrtc") != null || fs.stat("/usr/sbin/olcrtc") != null;
    status_obj.olcrtc_installed = olc_installed;
    if (olc_installed) {
        let olc_running = command_success_from_args(["pidof", "olcrtc"]);
        status_obj.olcrtc_running = olc_running;
        status_obj.olcrtc = olc_running ? "🟢 running" : "🔴 stopped";
    }

    // Eco / Lite mode
    let eco_mode = uci_core.get(CONFIG_NAME, "settings", "eco_mode") == "1" ||
                   uci_core.get(CONFIG_NAME, "settings", "lite_mode") == "1";
    status_obj.eco_mode = eco_mode;

    // Count available component updates in cache
    let updates_available_count = 0;
    try {
        for (let upath in (fs.glob("/var/run/tachyon/component-update-checks/*.json") || [])) {
            let uc_obj = common.read_json_file(upath);
            if (type(uc_obj) == "object" && uc_obj.success === true &&
                (uc_obj.status == "outdated" || uc_obj.status == "outdated_same_release")) {
                updates_available_count++;
            }
        }
    } catch (e) {}
    status_obj.updates_available_count = updates_available_count;

    status_obj.tachyon_running = command_success_from_args(["/etc/init.d/tachyon", "status"]);

    // Active servers for all Selector groups
    status_obj.active_servers = {};
    let meta = get_outbound_display_metadata();
    
    let pdata = get_clash_proxies_data();
    if (pdata && pdata.proxies) {
        for (let gname in keys(pdata.proxies)) {
            let p = pdata.proxies[gname];
            if (p.type == "Selector" || p.type == "URLTest" || p.type == "Fallback") {
                if (p.now) {
                    let srv_name = p.now;
                    let latency = "N/A";
                    let srv = pdata.proxies[srv_name];
                    if (srv && type(srv.history) == "array" && length(srv.history) > 0) {
                        let last = srv.history[length(srv.history) - 1];
                        if (last && last.delay) latency = last.delay;
                    } else if (srv && (srv.type == "URLTest" || srv.type == "Selector" || srv.type == "Fallback") && srv.now) {
                        let inner_srv = pdata.proxies[srv.now];
                        if (inner_srv && type(inner_srv.history) == "array" && length(inner_srv.history) > 0) {
                            let last = inner_srv.history[length(inner_srv.history) - 1];
                            if (last && last.delay) latency = last.delay;
                        }
                    }
                    let total_nodes = type(p.all) == "array" ? length(p.all) : 0;
                    status_obj.active_servers[gname] = {
                        server: srv_name,
                        display_name: format_outbound_display_name(srv_name, meta),
                        group_label: format_group_display_name(gname, meta),
                        latency: latency,
                        total_nodes: total_nodes
                    };
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
    let ver = "unknown";
    let opkg_out = common.command_output("opkg status tachyon 2>/dev/null | grep Version");
    if (opkg_out && trim(opkg_out) != "") {
        ver = split(trim(opkg_out), " ")[1];
    } else {
        let apk_out = common.command_output("apk list tachyon 2>/dev/null");
        if (apk_out && trim(apk_out) != "") {
            let m = match(apk_out, /tachyon-([0-9A-Za-z._+-]+)/);
            if (m && m[1]) ver = m[1];
        }
    }
    status_obj.tachyon_version = ver || "unknown";
    status_obj.tachyon_commit_sha = constants.TACHYON_COMMIT_SHA && !match(constants.TACHYON_COMMIT_SHA, /COMPILED/) ? constants.TACHYON_COMMIT_SHA : "";

    return status_obj;
}

function clash_request(method, endpoint, payload) {
    let url = get_clash_url(endpoint);
    // ucode has no Math global (math is a separate loadable module), so the
    // microsecond field of clock() supplies the uniqueness suffix, the same way
    // temp paths are built elsewhere in this codebase.
    let payload_path = "/tmp/clash_payload_" + method + "_" + time() + "_" + clock()[1] + ".json";
    let res = null;
    try {
        let args = [ "curl", "-s", "-m", "5", "--connect-timeout", "3", "-X", method ];
        for (let h in get_clash_auth_args()) push(args, h);
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
    
    if (!res || res.status != 0) {
        return null;
    }
    if (res.output == "") {
        return { success: true };
    }
    
    try {
        return json(res.output);
    }
    catch (e) {
        return res.output;
    }
}

function get_clash_connections() {
    let args = [ "curl", "-s", "-m", "5", "--connect-timeout", "3" ];
    for (let h in get_clash_auth_args()) push(args, h);
    push(args, get_clash_url("connections"));
    let res = command_capture(command_from_args(args));
    if (res && res.status == 0 && res.output != "") {
        try {
            return json(res.output);
        }
        catch (e) {
            // Falls through to null, which every caller already handles as "the
            // clash API gave us nothing" - the same result as a failed curl.
        }
    }
    return null;
}

function get_clash_traffic() {
    let args = [ "curl", "-s", "-m", "2", "--connect-timeout", "2" ];
    for (let h in get_clash_auth_args()) push(args, h);
    push(args, get_clash_url("traffic"));
    let res = command_capture(command_from_args(args));
    if (res && res.status == 0 && res.output != "") {
        try {
            let first_line = split(trim(res.output), "\n")[0];
            return json(first_line);
        }
        catch (e) {}
    }
    return null;
}

function http_probe(use_proxy) {
    let proxy_ep = common.get_mixed_proxy_endpoint ? common.get_mixed_proxy_endpoint() : ("127.0.0.1:" + common.get_mixed_port());
    // curl exits 0 for any completed HTTP exchange, including 4xx/5xx, so the
    // status code has to be inspected explicitly.
    let cmd = "curl -I -s -o /dev/null -m 8 --connect-timeout 4 -w '%{http_code}' " +
              (use_proxy ? "--proxy http://" + proxy_ep + " " : "") +
              "https://www.google.com";
    let res = command_capture(cmd);
    if (!res || res.status != 0) return false;
    let code = int(trim(as_string(res.output || "0")));
    return code >= 200 && code < 400;
}

function check_connection() {
    return { direct: http_probe(false), proxy: http_probe(true) };
}

function run_speedtest() {
    let proxy_ep = common.get_mixed_proxy_endpoint ? common.get_mixed_proxy_endpoint() : ("127.0.0.1:" + common.get_mixed_port());
    // Direct speedtest
    let res_direct = command_capture("curl -s -m 15 --connect-timeout 6 -w '%{speed_download}' -o /dev/null https://speed.cloudflare.com/__down?bytes=5242880");
    let direct_speed = (res_direct && res_direct.status == 0) ? double(res_direct.output || 0) : 0;
    let direct_mbps = (direct_speed * 8) / 1000000;

    // Proxy speedtest
    let res_proxy = command_capture("curl -s -m 15 --connect-timeout 6 --proxy http://" + proxy_ep + " -w '%{speed_download}' -o /dev/null https://speed.cloudflare.com/__down?bytes=5242880");
    let proxy_speed = (res_proxy && res_proxy.status == 0) ? double(res_proxy.output || 0) : 0;
    let proxy_mbps = (proxy_speed * 8) / 1000000;

    return {
        direct_mbps,
        proxy_mbps,
        direct_ok: direct_speed > 0,
        proxy_ok: proxy_speed > 0
    };
}

function run_leak_check(test_mode) {
    let leak_mod = require("diagnostics.leak_check");
    if (!leak_mod) return null;
    return leak_mod.run_leak_check(null, null, test_mode);
}

function run_ip_leak_check() {
    let leak_mod = require("diagnostics.leak_check");
    if (!leak_mod) return null;
    return leak_mod.check_ip_leak(null, null);
}

function run_dns_leak_check() {
    let leak_mod = require("diagnostics.leak_check");
    if (!leak_mod) return null;
    return leak_mod.check_dns_leak(null, null, null, null);
}

function run_leak_check_async(test_mode) {
    let leak_mod = require("diagnostics.leak_check");
    if (!leak_mod) return null;
    return leak_mod.start_leak_check_async(test_mode);
}

function run_leak_check_status(job_id) {
    let leak_mod = require("diagnostics.leak_check");
    if (!leak_mod) return null;
    return leak_mod.get_leak_check_status(job_id);
}

function manage_domain_list_by_section(sec_name, domain, do_delete) {
    let c = uci_core.cursor();
    if (!c) return { success: false, error: "Не удалось инициализировать UCI" };
    c.load(CONFIG_NAME);

    let s = c.get_all(CONFIG_NAME, sec_name);
    if (!s) {
        return { success: false, error: "Секция '" + sec_name + "' не найдена." };
    }

    let rendering = null;
    try { rendering = require("service.telegram.rendering"); } catch (e) {}
    let holders = rendering ? rendering.section_own_and_conditions(s) : [ s ];

    if (do_delete) {
        let deleted = false;
        for (let h in holders) {
            let hname = h[".name"];
            if (!hname) continue;
            for (let k in [ "domain", "domain_suffix", "user_domains" ]) {
                let opt_path = CONFIG_NAME + "." + hname + "." + k;
                for (let variant in [ domain, "domain:" + domain, "full:" + domain, "." + domain ]) {
                    if (uci_core.del_list(opt_path, variant))
                        deleted = true;
                }
            }
        }
        if (deleted) {
            uci_core.commit(CONFIG_NAME);
            common.command_status("/usr/bin/tachyon reload");
            return { success: true, message: "Запись <code>" + domain + "</code> удалена." };
        } else {
            return { success: false, error: "Запись <code>" + domain + "</code> не найдена." };
        }
    } else {
        if (rendering) {
            let existing = rendering.section_condition_values(s, "domain_suffix");
            let existing_exact = rendering.section_condition_values(s, "domain");
            for (let d in existing) {
                if (d == domain) return { success: false, error: "Запись <code>" + domain + "</code> уже есть в секции." };
            }
            for (let d in existing_exact) {
                if (d == domain) return { success: false, error: "Запись <code>" + domain + "</code> уже есть в секции." };
            }
        }
        let cond = rendering ? rendering.section_primary_atomic_condition(s) : null;
        let target_holder = (cond && cond[".name"]) ? cond[".name"] : sec_name;
        let target_key = cond ? "domain_suffix" : "domain";
        let option_path = CONFIG_NAME + "." + target_holder + "." + target_key;

        let current_val = uci_core.get(option_path);
        if (current_val != "") {
            for (let item in split(current_val, " ")) {
                if (item == domain)
                    return { success: false, error: "Запись <code>" + domain + "</code> уже есть в секции." };
            }
        }

        if (uci_core.add_list(option_path, domain)) {
            uci_core.commit(CONFIG_NAME);
            common.command_status("/usr/bin/tachyon reload");
            return { success: true, message: "Запись <code>" + domain + "</code> добавлена." };
        }
        return { success: false, error: "Не удалось добавить запись." };
    }
}

function manage_domain_list(action_type, domain, do_delete) {
    let c = uci_core.cursor();
    if (!c) return { success: false, error: "Не удалось инициализировать UCI" };
    c.load(CONFIG_NAME);

    let connections = null;
    try { connections = require("config.connections"); } catch (e) {}

    let target_section = null;
    c.foreach(CONFIG_NAME, "section", function(s) {
        if (s.enabled == "1") {
            if (s.action == action_type || (action_type == "proxy" && s.action == "connection")) {
                if (action_type == "proxy" && connections && !connections.is_remote_proxy_section(s))
                    return;
                target_section = s[".name"];
                return false;
            }
        }
    });

    if (!target_section) {
        return { success: false, error: "Не найдено активное правило с действием '" + action_type + "'." };
    }

    return manage_domain_list_by_section(target_section, domain, do_delete);
}

function get_sections() {
    let c = uci_core.cursor();
    if (!c) return [];
    c.load(CONFIG_NAME);
    
    let sections = [];
    c.foreach(CONFIG_NAME, "section", function(s) {
        push(sections, s);
    });
    return sections;
}

function get_servers() {
    let c = uci_core.cursor();
    if (!c) return [];
    c.load(CONFIG_NAME);
    
    let servers = [];
    c.foreach(CONFIG_NAME, "server", function(s) {
        push(servers, s);
    });
    return servers;
}

function reload_tachyon() {
    return common.command_status("/usr/bin/tachyon reload") == 0;
}

function toggle_section(sec_name) {
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

function route_explain(client, target, port, proto) {
    let route_explain_mod = require("diagnostics.route_explain");
    return route_explain_mod.explain_route(client, target, port, proto);
}

function get_config_plan(candidate, options) {
    let config_plan_mod = require("service.config_plan");
    return config_plan_mod.plan(candidate, options);
}

function get_known_good_status() {
    let kg_mod = require("service.known_good");
    return kg_mod.get_status();
}

function promote_known_good(reason, metrics) {
    let kg_mod = require("service.known_good");
    return kg_mod.promote(reason, metrics);
}

function rollback_known_good(reason, options) {
    let kg_mod = require("service.known_good");
    return kg_mod.rollback_to_known_good(reason, options);
}

function check_known_good_observation() {
    let kg_mod = require("service.known_good");
    return kg_mod.check_observation();
}

function create_support_bundle(target_path, options) {
    let sb_mod = require("service.support_bundle");
    return sb_mod.create_bundle(target_path, options);
}

return {
    get_clash_url,
    get_clash_secret,
    get_clash_auth_args,
    get_clash_traffic,
    get_pause_remaining,
    process_running_by_pidfile,
    get_system_status,
    country_code_to_flag,
    get_outbound_display_metadata,
    format_outbound_display_name,
    format_group_display_name,
    probe_group_delay,
    probe_all_groups_delay,
    get_clash_proxies_data,
    clash_request,
    get_clash_connections,
    check_connection,
    run_speedtest,
    run_leak_check,
    run_leak_check_async,
    run_leak_check_status,
    run_ip_leak_check,
    run_dns_leak_check,
    manage_domain_list,
    manage_domain_list_by_section,
    get_sections,
    get_servers,
    reload_tachyon,
    toggle_section,
    route_explain,
    get_config_plan,
    get_known_good_status,
    promote_known_good,
    rollback_known_good,
    check_known_good_observation,
    create_support_bundle
};
