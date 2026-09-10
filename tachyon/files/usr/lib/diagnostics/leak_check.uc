#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let constants = require("core.constants");
let uci_core = require("core.uci");

let as_string = common.as_string;
let command_capture = common.command_capture;
let command_status = common.command_status;
let shell_quote = common.shell_quote;

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const LEAK_JOB_DIR = "/var/run/tachyon/leak_check";

let _has_so_mark_cached = null;
function curl_supports_so_mark() {
    if (_has_so_mark_cached != null)
        return _has_so_mark_cached;
    _has_so_mark_cached = (command_status("curl --so-mark 0 -V >/dev/null 2>&1") == 0);
    return _has_so_mark_cached;
}

/**
 * Detect active WAN network interface/device name.
 * Prioritizes actual routing table default gateway device (e.g. pppoe-wan, eth1, br-wan),
 * avoiding IP-less physical interfaces from UCI network.wan.device under PPPoE/VLANs.
 */
function get_wan_interface() {
    // 1. Prefer default routing table lookup: the device carrying the default route
    // is guaranteed to be the active L3 interface.
    let route_res = command_capture("ip -4 route show default 2>/dev/null");
    if (route_res && route_res.status == 0 && route_res.output != "") {
        let m = match(route_res.output, /dev\s+([a-zA-Z0-9_\.\-]+)/);
        if (m && m[1])
            return trim(as_string(m[1]));
    }

    // 2. Fallback to UCI network inspection
    try {
        let cursor = uci_core.cursor();
        if (cursor) {
            cursor.load("network");
            let dev = cursor.get("network", "wan", "device") || cursor.get("network", "wan", "ifname");
            if (dev != null && dev != "")
                return trim(as_string(dev));
        }
    } catch (e) {
        // Fallback
    }

    return "";
}

/**
 * Read upstream ISP DNS servers assigned by DHCP/PPPoE from standard OpenWrt resolv files.
 */
function get_direct_dns_servers() {
    let servers = [];
    let seen = {};

    let candidate_paths = [
        "/tmp/resolv.conf.d/resolv.conf.auto",
        "/tmp/resolv.conf.auto",
        "/tmp/resolv.conf"
    ];

    for (let path in candidate_paths) {
        let content = fs.readfile(path);
        if (content == null)
            continue;

        let lines = split(as_string(content), "\n");
        for (let line in lines) {
            line = trim(line);
            if (substr(line, 0, 11) == "nameserver ") {
                let ns = trim(substr(line, 11));
                if (ns != "" && !seen[ns] &&
                    ns != "127.0.0.1" && ns != "127.0.0.42" && ns != "127.0.0.43" &&
                    ns != "::1" && index(ns, "127.0.") < 0) {
                    seen[ns] = true;
                    push(servers, {
                        ip: ns,
                        country: "",
                        isp: "ISP / WAN Local",
                        is_isp: true
                    });
                }
            }
        }
        if (length(servers) > 0)
            break;
    }

    return servers;
}

/**
 * Generate curl CLI flags for direct WAN routing bypassing Tachyon tproxy.
 */
function get_direct_curl_flags(wan_iface) {
    let parts = [];
    if (wan_iface != null && wan_iface != "") {
        push(parts, "--interface " + shell_quote(wan_iface));
    }

    if (curl_supports_so_mark()) {
        let mark = constants.NFT_OUTBOUND_MARK || "0x08000000";
        push(parts, "--so-mark " + shell_quote(mark));
    }

    return join(" ", parts);
}

/**
 * Parse IP, Country, City, and ISP from various JSON and plaintext endpoints.
 */
function parse_ip_response(text) {
    if (text == null || text == "")
        return null;

    // 1. Try JSON formats (api.ip.sb, ipwho.is, ipleak.net, api.ipify.org)
    try {
        let data = json(text);
        if (type(data) == "object" && data.ip != null && data.ip != "") {
            let isp = "";
            if (data.isp) {
                isp = as_string(data.isp);
            } else if (data.isp_name) {
                isp = as_string(data.isp_name);
            } else if (data.connection && (data.connection.isp || data.connection.org)) {
                isp = as_string(data.connection.isp || data.connection.org);
            } else if (data.organization) {
                isp = as_string(data.organization);
            }

            return {
                ip: as_string(data.ip),
                country: as_string(data.country || data.country_name || ""),
                country_code: as_string(data.country_code || ""),
                city: as_string(data.city || data.city_name || ""),
                isp: isp,
                ok: true
            };
        }
    } catch (e) {}

    // 2. Try Cloudflare cdn-cgi/trace (ip=..., loc=...)
    let m_ip = match(text, /ip=([0-9a-fA-F\.\:]+)/);
    if (m_ip && m_ip[1]) {
        let loc = "";
        let m_loc = match(text, /loc=([A-Z]{2})/);
        if (m_loc && m_loc[1])
            loc = m_loc[1];
        return {
            ip: m_ip[1],
            country: loc,
            country_code: loc,
            city: "",
            isp: "Cloudflare Anycast",
            ok: true
        };
    }

    // 3. Try plain IP address text
    let plain_ip = trim(text);
    if (match(plain_ip, /^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$/) || match(plain_ip, /^[0-9a-fA-F:]+$/)) {
        return {
            ip: plain_ip,
            country: "",
            country_code: "",
            city: "",
            isp: "",
            ok: true
        };
    }

    return null;
}

/**
 * Query public IP details with fast Anycast failover endpoints.
 */
function fetch_ip_info(use_proxy, wan_iface, mixed_port) {
    let proxy_flag = use_proxy ? ("--proxy http://127.0.0.1:" + mixed_port + " ") : "";
    let direct_flag = use_proxy ? "" : (get_direct_curl_flags(wan_iface) + " ");

    let endpoints = [
        "https://api.ip.sb/geoip",
        "https://ipwho.is/",
        "https://api.ipify.org?format=json",
        "https://cloudflare.com/cdn-cgi/trace"
    ];

    for (let ep in endpoints) {
        let cmd = sprintf("curl -s -m 3 --connect-timeout 2 %s%s%s 2>/dev/null", proxy_flag, direct_flag, shell_quote(ep));
        let res = command_capture(cmd);
        if (res && res.status == 0 && res.output != "") {
            let parsed = parse_ip_response(res.output);
            if (parsed != null && parsed.ok)
                return parsed;
        }
    }

    return {
        ip: "—",
        country: "",
        country_code: "",
        city: "",
        isp: "",
        ok: false
    };
}

/**
 * Check for IP Leaks by comparing direct WAN IP and proxy outbound IP.
 * Executes direct and proxy queries concurrently in parallel to avoid timeouts.
 */
function check_ip_leak(wan_iface, mixed_port) {
    mixed_port = mixed_port || common.get_mixed_port();
    wan_iface = wan_iface != null ? wan_iface : get_wan_interface();

    let tmp_res = command_capture("mktemp -d /tmp/tachyon_leak_ip_XXXXXX 2>/dev/null");
    let work_dir = (tmp_res && tmp_res.status == 0) ? trim(as_string(tmp_res.output)) : "";

    let direct = null;
    let proxy = null;

    if (work_dir != "") {
        let proxy_flag = "--proxy http://127.0.0.1:" + mixed_port;
        let direct_flags = get_direct_curl_flags(wan_iface);

        let cmd_direct = sprintf("( curl -s -m 3 --connect-timeout 2 %s https://api.ip.sb/geoip || curl -s -m 3 --connect-timeout 2 %s https://ipwho.is/ || curl -s -m 2 --connect-timeout 2 %s 'https://api.ipify.org?format=json' || curl -s -m 2 --connect-timeout 2 %s https://cloudflare.com/cdn-cgi/trace ) > %s/direct.out 2>/dev/null", direct_flags, direct_flags, direct_flags, direct_flags, work_dir);
        let cmd_proxy = sprintf("( curl -s -m 3 --connect-timeout 2 %s https://api.ip.sb/geoip || curl -s -m 3 --connect-timeout 2 %s https://ipwho.is/ || curl -s -m 2 --connect-timeout 2 %s 'https://api.ipify.org?format=json' || curl -s -m 2 --connect-timeout 2 %s https://cloudflare.com/cdn-cgi/trace ) > %s/proxy.out 2>/dev/null", proxy_flag, proxy_flag, proxy_flag, proxy_flag, work_dir);

        system(sprintf("{ %s & %s & wait; } 2>/dev/null", cmd_direct, cmd_proxy));

        let direct_out = fs.readfile(work_dir + "/direct.out");
        let proxy_out = fs.readfile(work_dir + "/proxy.out");

        direct = parse_ip_response(direct_out);
        proxy = parse_ip_response(proxy_out);

        system(sprintf("rm -rf %s 2>/dev/null", shell_quote(work_dir)));
    }

    if (direct == null)
        direct = fetch_ip_info(false, wan_iface, mixed_port);
    if (proxy == null)
        proxy = fetch_ip_info(true, wan_iface, mixed_port);

    let proxy_online = (proxy.ok && proxy.ip != "—");
    let leaked = false;

    if (proxy_online && direct.ok && direct.ip != "—") {
        leaked = (proxy.ip == direct.ip);
    }

    return {
        leaked: leaked,
        direct_ip: direct.ip,
        direct_country: direct.country,
        direct_country_code: direct.country_code,
        direct_city: direct.city,
        direct_isp: direct.isp,
        proxy_ip: proxy.ip,
        proxy_country: proxy.country,
        proxy_country_code: proxy.country_code,
        proxy_city: proxy.city,
        proxy_org: proxy.isp,
        proxy_online: proxy_online
    };
}

/**
 * Check for DNS Leaks using the bash.ws DNS Leak detection protocol.
 * Queries tokens and results in parallel with fast timeouts and OpenWrt resolv fallback.
 */
function check_dns_leak(wan_iface, mixed_port, direct_ip, proxy_ip) {
    mixed_port = mixed_port || common.get_mixed_port();
    wan_iface = wan_iface != null ? wan_iface : get_wan_interface();

    let direct_dns_servers = get_direct_dns_servers();

    let direct_flags = get_direct_curl_flags(wan_iface);
    let proxy_flag = "--proxy http://127.0.0.1:" + mixed_port;

    let tmp_res = command_capture("mktemp -d /tmp/tachyon_leak_dns_XXXXXX 2>/dev/null");
    let work_dir = (tmp_res && tmp_res.status == 0) ? trim(as_string(tmp_res.output)) : "";

    let direct_id = "";
    let proxy_id = "";
    let direct_resolvers = [];
    let proxy_resolvers = [];

    if (work_dir != "") {
        // Step 1: Concurrently fetch leak tokens
        let cmd_direct_id = sprintf("curl -s -m 3 --connect-timeout 2 %s https://bash.ws/id > %s/direct_id 2>/dev/null", direct_flags, work_dir);
        let cmd_proxy_id = sprintf("curl -s -m 3 --connect-timeout 2 %s https://bash.ws/id > %s/proxy_id 2>/dev/null", proxy_flag, work_dir);
        system(sprintf("{ %s & %s & wait; } 2>/dev/null", cmd_direct_id, cmd_proxy_id));

        direct_id = trim(as_string(fs.readfile(work_dir + "/direct_id") || ""));
        proxy_id = trim(as_string(fs.readfile(work_dir + "/proxy_id") || ""));

        // Step 2: Fire parallel DNS queries for subdomains
        if (direct_id != "" || proxy_id != "") {
            let burst_cmd = "{ ";
            if (direct_id != "") {
                for (let i = 1; i <= 4; i++) {
                    burst_cmd += sprintf("curl -s -m 2 %s http://%d.%s.bash.ws >/dev/null 2>&1 & ", direct_flags, i, direct_id);
                }
            }
            if (proxy_id != "") {
                for (let i = 1; i <= 4; i++) {
                    burst_cmd += sprintf("curl -s -m 2 %s http://%d.%s.bash.ws >/dev/null 2>&1 & ", proxy_flag, i, proxy_id);
                }
            }
            burst_cmd += "wait; } 2>/dev/null";
            system(burst_cmd);

            // Allow 1s propagation time for upstream resolvers
            system("sleep 1 2>/dev/null");

            // Step 3: Concurrently fetch results
            let cmd_res_direct = "";
            let cmd_res_proxy = "";
            if (direct_id != "") {
                cmd_res_direct = sprintf("curl -s -m 3 --connect-timeout 2 %s 'https://bash.ws/dnsleak/test/%s?json' > %s/direct_res 2>/dev/null & ", direct_flags, direct_id, work_dir);
            }
            if (proxy_id != "") {
                cmd_res_proxy = sprintf("curl -s -m 3 --connect-timeout 2 %s 'https://bash.ws/dnsleak/test/%s?json' > %s/proxy_res 2>/dev/null & ", proxy_flag, proxy_id, work_dir);
            }
            if (cmd_res_direct != "" || cmd_res_proxy != "") {
                system(sprintf("{ %s%swait; } 2>/dev/null", cmd_res_direct, cmd_res_proxy));
            }

            if (direct_id != "") {
                let text = fs.readfile(work_dir + "/direct_res");
                if (text) {
                    try {
                        let parsed = json(text);
                        if (type(parsed) == "array") direct_resolvers = parsed;
                    } catch (e) {}
                }
            }
            if (proxy_id != "") {
                let text = fs.readfile(work_dir + "/proxy_res");
                if (text) {
                    try {
                        let parsed = json(text);
                        if (type(parsed) == "array") proxy_resolvers = parsed;
                    } catch (e) {}
                }
            }
        }

        system(sprintf("rm -rf %s 2>/dev/null", shell_quote(work_dir)));
    }

    // Build lookup table of direct / ISP DNS resolvers
    let direct_map = {};
    for (let s in direct_dns_servers) {
        if (s.ip) direct_map[s.ip] = true;
    }
    for (let r in direct_resolvers) {
        if (r.ip) direct_map[r.ip] = true;
    }

    let formatted_proxy_servers = [];
    let leak_found = false;

    for (let pr in proxy_resolvers) {
        if (type(pr) != "object" || !pr.ip) continue;

        let is_direct_leak = (direct_map[pr.ip] == true);
        if (is_direct_leak) {
            leak_found = true;
        }

        push(formatted_proxy_servers, {
            ip: pr.ip,
            country: as_string(pr.country || pr.country_name || ""),
            isp: as_string(pr.name || pr.asn || "Unknown"),
            is_isp: is_direct_leak
        });
    }

    let formatted_direct_servers = [];
    for (let dr in direct_resolvers) {
        if (type(dr) != "object" || !dr.ip) continue;
        push(formatted_direct_servers, {
            ip: dr.ip,
            country: as_string(dr.country || dr.country_name || ""),
            isp: as_string(dr.name || dr.asn || "ISP Upstream"),
            is_isp: true
        });
    }

    // Fallback: If bash.ws returned no direct resolvers, populate with OpenWrt system resolv servers
    if (length(formatted_direct_servers) == 0 && length(direct_dns_servers) > 0) {
        formatted_direct_servers = direct_dns_servers;
    }

    let proxy_online = (proxy_id != "" || (proxy_ip != null && proxy_ip != "" && proxy_ip != "—"));
    let dns_leaked = false;

    if (proxy_online && length(formatted_proxy_servers) > 0) {
        dns_leaked = leak_found;
    } else if (proxy_online && length(formatted_proxy_servers) == 0) {
        dns_leaked = false;
    }

    // If proxy IP equals direct IP, then DNS is definitely not shielded
    if (proxy_ip != null && direct_ip != null && proxy_ip != "—" && direct_ip != "—" && proxy_ip == direct_ip) {
        dns_leaked = true;
    }

    return {
        dns_leaked: dns_leaked,
        direct_ip: direct_ip || "—",
        proxy_ip: proxy_ip || "—",
        dns_servers: formatted_proxy_servers,
        direct_dns_servers: formatted_direct_servers,
        proxy_online: proxy_online
    };
}

/**
 * Unified diagnostic check for both IP and DNS leaks.
 * Runs IP and DNS token acquisition concurrently, completing in 3-4s total.
 */
function run_leak_check(wan_iface, mixed_port) {
    mixed_port = mixed_port || common.get_mixed_port();
    wan_iface = wan_iface != null ? wan_iface : get_wan_interface();

    let tmp_res = command_capture("mktemp -d /tmp/tachyon_leak_all_XXXXXX 2>/dev/null");
    let work_dir = (tmp_res && tmp_res.status == 0) ? trim(as_string(tmp_res.output)) : "";

    if (work_dir == "") {
        let ip_res = check_ip_leak(wan_iface, mixed_port);
        let dns_res = check_dns_leak(wan_iface, mixed_port, ip_res.direct_ip, ip_res.proxy_ip);
        return {
            ip_leak: ip_res,
            dns_leak: dns_res,
            timestamp: time()
        };
    }

    let direct_dns_servers = get_direct_dns_servers();
    let direct_flags = get_direct_curl_flags(wan_iface);
    let proxy_flag = "--proxy http://127.0.0.1:" + mixed_port;

    // Stage 1: Run all 4 probes concurrently (direct IP, proxy IP, direct bash.ws ID, proxy bash.ws ID)
    let cmd_direct_ip = sprintf("( curl -s -m 3 --connect-timeout 2 %s https://api.ip.sb/geoip || curl -s -m 3 --connect-timeout 2 %s https://ipwho.is/ || curl -s -m 2 --connect-timeout 2 %s 'https://api.ipify.org?format=json' || curl -s -m 2 --connect-timeout 2 %s https://cloudflare.com/cdn-cgi/trace ) > %s/direct_ip.out 2>/dev/null", direct_flags, direct_flags, direct_flags, direct_flags, work_dir);
    let cmd_proxy_ip = sprintf("( curl -s -m 3 --connect-timeout 2 %s https://api.ip.sb/geoip || curl -s -m 3 --connect-timeout 2 %s https://ipwho.is/ || curl -s -m 2 --connect-timeout 2 %s 'https://api.ipify.org?format=json' || curl -s -m 2 --connect-timeout 2 %s https://cloudflare.com/cdn-cgi/trace ) > %s/proxy_ip.out 2>/dev/null", proxy_flag, proxy_flag, proxy_flag, proxy_flag, work_dir);
    let cmd_direct_id = sprintf("curl -s -m 3 --connect-timeout 2 %s https://bash.ws/id > %s/direct_id.out 2>/dev/null", direct_flags, work_dir);
    let cmd_proxy_id = sprintf("curl -s -m 3 --connect-timeout 2 %s https://bash.ws/id > %s/proxy_id.out 2>/dev/null", proxy_flag, work_dir);

    system(sprintf("{ %s & %s & %s & %s & wait; } 2>/dev/null", cmd_direct_ip, cmd_proxy_ip, cmd_direct_id, cmd_proxy_id));

    let direct_ip_info = parse_ip_response(fs.readfile(work_dir + "/direct_ip.out"));
    let proxy_ip_info = parse_ip_response(fs.readfile(work_dir + "/proxy_ip.out"));
    let direct_id = trim(as_string(fs.readfile(work_dir + "/direct_id.out") || ""));
    let proxy_id = trim(as_string(fs.readfile(work_dir + "/proxy_id.out") || ""));

    if (direct_ip_info == null) direct_ip_info = fetch_ip_info(false, wan_iface, mixed_port);
    if (proxy_ip_info == null) proxy_ip_info = fetch_ip_info(true, wan_iface, mixed_port);

    // Stage 2: DNS queries & result retrieval
    let direct_resolvers = [];
    let proxy_resolvers = [];

    if (direct_id != "" || proxy_id != "") {
        let burst_cmd = "{ ";
        if (direct_id != "") {
            for (let i = 1; i <= 4; i++) {
                burst_cmd += sprintf("curl -s -m 2 %s http://%d.%s.bash.ws >/dev/null 2>&1 & ", direct_flags, i, direct_id);
            }
        }
        if (proxy_id != "") {
            for (let i = 1; i <= 4; i++) {
                burst_cmd += sprintf("curl -s -m 2 %s http://%d.%s.bash.ws >/dev/null 2>&1 & ", proxy_flag, i, proxy_id);
            }
        }
        burst_cmd += "wait; } 2>/dev/null";
        system(burst_cmd);

        system("sleep 1 2>/dev/null");

        let cmd_res_direct = "";
        let cmd_res_proxy = "";
        if (direct_id != "") {
            cmd_res_direct = sprintf("curl -s -m 3 --connect-timeout 2 %s 'https://bash.ws/dnsleak/test/%s?json' > %s/direct_res 2>/dev/null & ", direct_flags, direct_id, work_dir);
        }
        if (proxy_id != "") {
            cmd_res_proxy = sprintf("curl -s -m 3 --connect-timeout 2 %s 'https://bash.ws/dnsleak/test/%s?json' > %s/proxy_res 2>/dev/null & ", proxy_flag, proxy_id, work_dir);
        }
        if (cmd_res_direct != "" || cmd_res_proxy != "") {
            system(sprintf("{ %s%swait; } 2>/dev/null", cmd_res_direct, cmd_res_proxy));
        }

        if (direct_id != "") {
            let text = fs.readfile(work_dir + "/direct_res");
            if (text) {
                try {
                    let parsed = json(text);
                    if (type(parsed) == "array") direct_resolvers = parsed;
                } catch (e) {}
            }
        }
        if (proxy_id != "") {
            let text = fs.readfile(work_dir + "/proxy_res");
            if (text) {
                try {
                    let parsed = json(text);
                    if (type(parsed) == "array") proxy_resolvers = parsed;
                } catch (e) {}
            }
        }
    }

    system(sprintf("rm -rf %s 2>/dev/null", shell_quote(work_dir)));

    // Assemble IP check result
    let proxy_online = (proxy_ip_info.ok && proxy_ip_info.ip != "—");
    let ip_leaked = false;
    if (proxy_online && direct_ip_info.ok && direct_ip_info.ip != "—") {
        ip_leaked = (proxy_ip_info.ip == direct_ip_info.ip);
    }

    let ip_res = {
        leaked: ip_leaked,
        direct_ip: direct_ip_info.ip,
        direct_country: direct_ip_info.country,
        direct_country_code: direct_ip_info.country_code,
        direct_city: direct_ip_info.city,
        direct_isp: direct_ip_info.isp,
        proxy_ip: proxy_ip_info.ip,
        proxy_country: proxy_ip_info.country,
        proxy_country_code: proxy_ip_info.country_code,
        proxy_city: proxy_ip_info.city,
        proxy_org: proxy_ip_info.isp,
        proxy_online: proxy_online
    };

    // Assemble DNS check result
    let direct_map = {};
    for (let s in direct_dns_servers) {
        if (s.ip) direct_map[s.ip] = true;
    }
    for (let r in direct_resolvers) {
        if (r.ip) direct_map[r.ip] = true;
    }

    let formatted_proxy_servers = [];
    let leak_found = false;

    for (let pr in proxy_resolvers) {
        if (type(pr) != "object" || !pr.ip) continue;

        let is_direct_leak = (direct_map[pr.ip] == true);
        if (is_direct_leak) {
            leak_found = true;
        }

        push(formatted_proxy_servers, {
            ip: pr.ip,
            country: as_string(pr.country || pr.country_name || ""),
            isp: as_string(pr.name || pr.asn || "Unknown"),
            is_isp: is_direct_leak
        });
    }

    let formatted_direct_servers = [];
    for (let dr in direct_resolvers) {
        if (type(dr) != "object" || !dr.ip) continue;
        push(formatted_direct_servers, {
            ip: dr.ip,
            country: as_string(dr.country || dr.country_name || ""),
            isp: as_string(dr.name || dr.asn || "ISP Upstream"),
            is_isp: true
        });
    }

    if (length(formatted_direct_servers) == 0 && length(direct_dns_servers) > 0) {
        formatted_direct_servers = direct_dns_servers;
    }

    let dns_proxy_online = (proxy_id != "" || (ip_res.proxy_ip != null && ip_res.proxy_ip != "" && ip_res.proxy_ip != "—"));
    let dns_leaked = false;

    if (dns_proxy_online && length(formatted_proxy_servers) > 0) {
        dns_leaked = leak_found;
    } else if (dns_proxy_online && length(formatted_proxy_servers) == 0) {
        dns_leaked = false;
    }

    if (ip_res.proxy_ip != null && ip_res.direct_ip != null && ip_res.proxy_ip != "—" && ip_res.direct_ip != "—" && ip_res.proxy_ip == ip_res.direct_ip) {
        dns_leaked = true;
    }

    let dns_res = {
        dns_leaked: dns_leaked,
        direct_ip: ip_res.direct_ip,
        proxy_ip: ip_res.proxy_ip,
        dns_servers: formatted_proxy_servers,
        direct_dns_servers: formatted_direct_servers,
        proxy_online: dns_proxy_online
    };

    return {
        ip_leak: ip_res,
        dns_leak: dns_res,
        timestamp: time()
    };
}

/**
 * Start asynchronous leak check job and return job_id.
 */
function start_leak_check_async() {
    common.ensure_dir("/var/run/tachyon");
    common.ensure_dir(LEAK_JOB_DIR);

    let id = sprintf("%d_%d", time(), int(clock()[1] % 10000));
    let path = sprintf("%s/%s.json", LEAK_JOB_DIR, id);

    let initial_state = {
        running: true,
        job_id: id,
        progress: 25,
        stage: "ip",
        started_at: time()
    };

    if (!common.write_json_file(path, initial_state)) {
        print(sprintf("%J\n", { success: false, error: "Failed to initialize leak check job state" }));
        exit(1);
    }

    let lib_dir = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
    let mod_file = lib_dir + "/diagnostics/leak_check.uc";
    let worker_cmd = sprintf("TACHYON_LIB=%s ucode -L %s %s leak-check-worker %s", shell_quote(lib_dir), shell_quote(lib_dir), shell_quote(mod_file), shell_quote(id));

    let bg_cmd = common.background_command_with_pid(worker_cmd);
    command_capture("sh -c " + shell_quote(bg_cmd));

    print(sprintf("%J\n", { success: true, job_id: id }));
    exit(0);
}

/**
 * Worker executing leak check in background and recording final state.
 */
function leak_check_worker(job_id) {
    if (job_id == null || job_id == "")
        exit(1);

    common.ensure_dir("/var/run/tachyon");
    common.ensure_dir(LEAK_JOB_DIR);

    let path = sprintf("%s/%s.json", LEAK_JOB_DIR, job_id);
    common.write_json_file(path, {
        running: true,
        job_id: job_id,
        progress: 50,
        stage: "dns",
        started_at: time()
    });

    let res = run_leak_check(null, null);

    common.write_json_file(path, {
        running: false,
        success: true,
        job_id: job_id,
        progress: 100,
        stage: "done",
        data: res,
        finished_at: time()
    });

    // Cleanup old completed job files (> 10 minutes old)
    let cutoff = time() - 600;
    for (let f_path in (fs.glob(LEAK_JOB_DIR + "/*.json") || [])) {
        let st = fs.stat(f_path);
        if (st && st.mtime < cutoff) {
            try { fs.unlink(f_path); } catch (e) {}
        }
    }

    exit(0);
}

/**
 * Poll status of asynchronous leak check job.
 */
function get_leak_check_status(job_id) {
    if (job_id == null || job_id == "") {
        print(sprintf("%J\n", { success: false, error: "Job ID is required" }));
        exit(1);
    }

    let path = sprintf("%s/%s.json", LEAK_JOB_DIR, job_id);
    if (!fs.stat(path)) {
        print(sprintf("%J\n", { success: false, error: "Job not found" }));
        exit(1);
    }

    let state = common.read_json_file(path);
    if (state == null) {
        print(sprintf("%J\n", { success: false, error: "Failed to read job state" }));
        exit(1);
    }

    // Timeout check: if worker died or hung for more than 40 seconds
    if (state.running && (time() - state.started_at > 40)) {
        state.running = false;
        state.success = false;
        state.error = "IP & DNS leak test timed out on router";
        common.write_json_file(path, state);
    }

    print(sprintf("%J\n", state));
    exit(0);
}

function print_cli_summary(res) {
    print("\n=== TACHYON IP & DNS LEAK TEST REPORT ===\n\n");
    print(sprintf("Direct WAN IP : %s (%s, %s)\n", res.ip_leak.direct_ip, res.ip_leak.direct_country || "Unknown", res.ip_leak.direct_isp || "ISP"));
    print(sprintf("Proxy Outbound: %s (%s, %s)\n", res.ip_leak.proxy_ip, res.ip_leak.proxy_country || "Unknown", res.ip_leak.proxy_org || "Proxy"));

    if (res.ip_leak.proxy_online) {
        if (res.ip_leak.leaked) {
            print("IP Status     : ❌ LEAK DETECTED (Direct and Proxy IP match!)\n");
        } else {
            print("IP Status     : ✅ SECURE (Real WAN IP is hidden behind proxy)\n");
        }
    } else {
        print("IP Status     : ⚪ Proxy is offline or unreachable\n");
    }

    print("\n--- DNS Resolvers Detected ---\n");
    if (length(res.dns_leak.dns_servers) > 0) {
        for (let s in res.dns_leak.dns_servers) {
            let flag = s.is_isp ? "❌ ISP LEAK" : "✅ SECURE";
            print(sprintf("  [%s] %s (%s - %s)\n", flag, s.ip, s.country, s.isp));
        }
    } else {
        print("  (No proxy DNS queries recorded or proxy offline)\n");
    }

    if (res.dns_leak.dns_leaked) {
        print("\nDNS Status    : ❌ DNS LEAK DETECTED (Queries reach your local ISP!)\n\n");
    } else {
        print("\nDNS Status    : ✅ SECURE (All DNS routed through encrypted/proxy resolvers)\n\n");
    }
}

// --- CLI Dispatcher ---
let mode = ARGV[0] || "";

if (mode == "leak-check" || mode == "leak_check") {
    let res = run_leak_check(null, null);
    if (ARGV[1] == "--pretty" || ARGV[1] == "-p") {
        print_cli_summary(res);
    } else {
        print(sprintf("%J\n", res));
    }
    exit(0);
}
else if (mode == "leak-check-async" || mode == "leak_check_async") {
    start_leak_check_async();
}
else if (mode == "leak-check-worker") {
    leak_check_worker(ARGV[1]);
}
else if (mode == "leak-check-status" || mode == "leak_check_status") {
    get_leak_check_status(ARGV[1]);
}
else if (mode == "ip-leak" || mode == "check_ip_leak") {
    let res = check_ip_leak(null, null);
    print(sprintf("%J\n", res));
    exit(0);
}
else if (mode == "dns-leak" || mode == "check_dns_leak") {
    let res = check_dns_leak(null, null, null, null);
    print(sprintf("%J\n", res));
    exit(0);
}

return {
    get_wan_interface,
    get_direct_dns_servers,
    get_direct_curl_flags,
    fetch_ip_info,
    check_ip_leak,
    check_dns_leak,
    run_leak_check,
    start_leak_check_async,
    get_leak_check_status
};
