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

let _has_so_mark_cached = null;
function curl_supports_so_mark() {
    if (_has_so_mark_cached != null)
        return _has_so_mark_cached;
    _has_so_mark_cached = (command_status("curl --so-mark 0 -V >/dev/null 2>&1") == 0);
    return _has_so_mark_cached;
}

/**
 * Detect active WAN network interface/device name.
 */
function get_wan_interface() {
    try {
        let cursor = uci_core.cursor();
        if (cursor) {
            cursor.load("network");
            let dev = cursor.get("network", "wan", "device") || cursor.get("network", "wan", "ifname");
            if (dev != null && dev != "")
                return trim(as_string(dev));
        }
    } catch (e) {
        // Fallback to routing inspection below
    }

    let route_res = command_capture("ip -4 route show default 2>/dev/null");
    if (route_res && route_res.status == 0 && route_res.output != "") {
        let m = match(route_res.output, /dev\s+([a-zA-Z0-9_\.\-]+)/);
        if (m && m[1])
            return trim(as_string(m[1]));
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
 * Query public IP details with fallback services.
 */
function fetch_ip_info(use_proxy, wan_iface, mixed_port) {
    let proxy_flag = use_proxy ? ("--proxy http://127.0.0.1:" + mixed_port + " ") : "";
    let direct_flag = use_proxy ? "" : (get_direct_curl_flags(wan_iface) + " ");

    let flags = "-s -m 7 --connect-timeout 4 " + proxy_flag + direct_flag;

    // 1. Try ipleak.net JSON API
    let res = command_capture("curl " + flags + "https://ipleak.net/json/ 2>/dev/null");
    if (res && res.status == 0 && res.output != "") {
        try {
            let data = json(res.output);
            if (type(data) == "object" && data.ip != null && data.ip != "") {
                return {
                    ip: as_string(data.ip),
                    country: as_string(data.country_name || ""),
                    country_code: as_string(data.country_code || ""),
                    city: as_string(data.city_name || ""),
                    isp: as_string(data.isp_name || ""),
                    ok: true
                };
            }
        } catch (e) {
            // Fall through to fallback
        }
    }

    // 2. Fallback to api.ipify.org
    res = command_capture("curl -s -m 5 --connect-timeout 3 " + proxy_flag + direct_flag + "'https://api.ipify.org?format=json' 2>/dev/null");
    if (res && res.status == 0 && res.output != "") {
        try {
            let data = json(res.output);
            if (type(data) == "object" && data.ip != null && data.ip != "") {
                return {
                    ip: as_string(data.ip),
                    country: "",
                    country_code: "",
                    city: "",
                    isp: "",
                    ok: true
                };
            }
        } catch (e) {
            // Fall through
        }
    }

    // 3. Fallback to ifconfig.me
    res = command_capture("curl -s -m 5 --connect-timeout 3 " + proxy_flag + direct_flag + "https://ifconfig.me/ip 2>/dev/null");
    if (res && res.status == 0 && res.output != "") {
        let ip = trim(as_string(res.output));
        if (ip != "" && match(ip, /^[0-9a-fA-F\.\:]+$/)) {
            return {
                ip: ip,
                country: "",
                country_code: "",
                city: "",
                isp: "",
                ok: true
            };
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
 */
function check_ip_leak(wan_iface, mixed_port) {
    mixed_port = mixed_port || common.get_mixed_port();
    wan_iface = wan_iface != null ? wan_iface : get_wan_interface();

    let direct = fetch_ip_info(false, wan_iface, mixed_port);
    let proxy = fetch_ip_info(true, wan_iface, mixed_port);

    let proxy_online = (proxy.ok && proxy.ip != "—");
    let leaked = true;

    if (proxy_online && direct.ok && direct.ip != "—") {
        leaked = (proxy.ip == direct.ip);
    } else if (proxy_online) {
        leaked = false;
    } else {
        leaked = false;
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
 */
function check_dns_leak(wan_iface, mixed_port, direct_ip, proxy_ip) {
    mixed_port = mixed_port || common.get_mixed_port();
    wan_iface = wan_iface != null ? wan_iface : get_wan_interface();

    let direct_dns_servers = get_direct_dns_servers();

    let direct_flags = get_direct_curl_flags(wan_iface);
    let proxy_flag = "--proxy http://127.0.0.1:" + mixed_port;

    // 1. Get unique leak tokens from bash.ws/id
    let res_direct_id = command_capture("curl -s -m 6 --connect-timeout 4 " + direct_flags + " https://bash.ws/id 2>/dev/null");
    let direct_id = (res_direct_id && res_direct_id.status == 0) ? trim(as_string(res_direct_id.output)) : "";

    let res_proxy_id = command_capture("curl -s -m 6 --connect-timeout 4 " + proxy_flag + " https://bash.ws/id 2>/dev/null");
    let proxy_id = (res_proxy_id && res_proxy_id.status == 0) ? trim(as_string(res_proxy_id.output)) : "";

    // 2. Fire parallel DNS queries for bash.ws subdomains
    if (direct_id != "" || proxy_id != "") {
        let parallel_cmd = "{ ";
        if (direct_id != "") {
            for (let i = 1; i <= 6; i++) {
                parallel_cmd += sprintf("curl -s -m 3 %s http://%d.%s.bash.ws >/dev/null 2>&1 & ", direct_flags, i, direct_id);
            }
        }
        if (proxy_id != "") {
            for (let i = 1; i <= 6; i++) {
                parallel_cmd += sprintf("curl -s -m 3 %s http://%d.%s.bash.ws >/dev/null 2>&1 & ", proxy_flag, i, proxy_id);
            }
        }
        parallel_cmd += "wait; } 2>/dev/null";
        system(parallel_cmd);

        // Allow 1.5s propagation time for upstream resolvers
        system("sleep 1.5 2>/dev/null || sleep 2 2>/dev/null");
    }

    // 3. Fetch test results from bash.ws
    let direct_resolvers = [];
    if (direct_id != "") {
        let res = command_capture("curl -s -m 6 --connect-timeout 4 " + direct_flags + " 'https://bash.ws/dnsleak/test/" + direct_id + "?json' 2>/dev/null");
        if (res && res.status == 0 && res.output != "") {
            try {
                let parsed = json(res.output);
                if (type(parsed) == "array")
                    direct_resolvers = parsed;
            } catch (e) {}
        }
    }

    let proxy_resolvers = [];
    if (proxy_id != "") {
        let res = command_capture("curl -s -m 6 --connect-timeout 4 " + proxy_flag + " 'https://bash.ws/dnsleak/test/" + proxy_id + "?json' 2>/dev/null");
        if (res && res.status == 0 && res.output != "") {
            try {
                let parsed = json(res.output);
                if (type(parsed) == "array")
                    proxy_resolvers = parsed;
            } catch (e) {}
        }
    }

    // 4. Build lookup table of direct / ISP DNS resolvers
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
 */
function run_leak_check(wan_iface, mixed_port) {
    mixed_port = mixed_port || common.get_mixed_port();
    wan_iface = wan_iface != null ? wan_iface : get_wan_interface();

    let ip_res = check_ip_leak(wan_iface, mixed_port);
    let dns_res = check_dns_leak(wan_iface, mixed_port, ip_res.direct_ip, ip_res.proxy_ip);

    return {
        ip_leak: ip_res,
        dns_leak: dns_res,
        timestamp: time()
    };
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
    run_leak_check
};
