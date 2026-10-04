#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let constants = require("core.constants");
let uci_core = require("core.uci");
let ip_utils = require("core.ip");
let transport = require("diagnostics.dns_transport");

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

function is_tcp_port_listening(port) {
    if (!port || int(port) <= 0)
        return false;
    let hex_port = sprintf(":%04X", int(port));
    // Local addresses in /proc/net/tcp are little-endian 32-bit hex. Loopback
    // (127.0.0.1) is "0100007F"; wildcard bind is "00000000". IPv6 loopback is
    // "00000000000000000000000001000000". Only loopback/wildcard listeners
    // count: the mixed inbound is loopback-only, so a matching port on another
    // interface must not make the proxy look reachable.
    const LOOPBACK_V4 = "0100007F";
    const WILDCARD_V4 = "00000000";
    const LOOPBACK_V6 = "00000000000000000000000001000000";
    const WILDCARD_V6 = "00000000000000000000000000000000";
    for (let path in [ "/proc/net/tcp", "/proc/net/tcp6" ]) {
        let content = fs.readfile(path);
        if (!content)
            continue;
        let lines = split(as_string(content), "\n");
        for (let line in lines) {
            line = trim(line);
            if (line == "")
                continue;
            let fields = split(line, /[ \t]+/);
            if (length(fields) < 4)
                continue;
            let local = fields[1];
            if (local == null)
                continue;
            let sep = rindex(local, ":");
            if (sep < 0)
                continue;
            let listen_port = substr(local, sep); // includes leading ':'
            if (lc(listen_port) != lc(hex_port))
                continue;
            let addr = substr(local, 0, sep);
            if (addr == LOOPBACK_V4 || addr == WILDCARD_V4 ||
                addr == LOOPBACK_V6 || addr == WILDCARD_V6)
                return true;
        }
    }
    return false;
}

/*
 * Public/anycast DNS resolvers are identified by exact IP first. Brand name
 * matching is only used to recognise *vendor-owned* resolvers, and it is
 * deliberately anchored to the operator/ASN field rather than arbitrary
 * substrings of a free-text name: a substring like "yandex" or "google" also
 * appears in the reverse-DNS / org of countless ISP resolvers, which would
 * mask a real leak as "safe". Matching is performed on word boundaries of the
 * ASN/organization string, never on the resolver's own hostname.
 */
const KNOWN_PUBLIC_DNS_IPS = {
    "1.1.1.1": "cloudflare", "1.0.0.1": "cloudflare", "1.1.1.2": "cloudflare", "1.0.0.2": "cloudflare",
    "1.1.1.3": "cloudflare", "1.0.0.3": "cloudflare",
    "8.8.8.8": "google", "8.8.4.4": "google", "8.8.8.0": "google",
    "9.9.9.9": "quad9", "149.112.112.112": "quad9", "9.9.9.10": "quad9", "149.112.112.10": "quad9",
    "208.67.222.222": "opendns", "208.67.220.220": "opendns",
    "94.140.14.14": "adguard", "94.140.15.15": "adguard", "94.140.14.140": "adguard", "94.140.14.141": "adguard",
    "4.2.2.1": "level3", "4.2.2.2": "level3", "4.2.2.3": "level3", "4.2.2.4": "level3",
    "185.228.168.9": "cleanbrowsing", "185.228.169.9": "cleanbrowsing",
    "76.76.2.0": "controld", "76.76.10.0": "controld",
    "45.90.28.0": "nextdns", "45.90.30.0": "nextdns",
    "194.242.2.2": "mullvad", "194.242.2.3": "mullvad",
    "185.222.222.222": "dns.sb", "45.11.45.11": "dns.sb"
};

/* Organization/ASN tokens that identify a *vendor-operated* public resolver.
 * These are matched on word boundaries against the operator field only. */
const VENDOR_ASN_TOKENS = [
    "cloudflare", "google", "quad9", "opendns", "cisco",
    "adguard", "nextdns", "controld", "mullvad", "cleanbrowsing",
    "dns.sb", "dnssb", "level 3", "level3", "lumen", "centurylink",
    "he.net", "hurricane electric"
];

/* Yandex DNS (77.88.8.x) is a public resolver, but "yandex" also names the
 * operator of many Russian ISP networks; only the exact Yandex DNS IPs and the
 * Yandex DNS ASN are treated as public. */
const YANDEX_DNS_IPS = {
    "77.88.8.8": true, "77.88.8.1": true, "77.88.8.2": true, "77.88.8.3": true,
    "77.88.8.7": true, "77.88.8.88": true
};

function vendor_matches(text) {
    text = lc(trim(as_string(text || "")));
    if (text == "")
        return "";
    for (let token in VENDOR_ASN_TOKENS) {
        if (index(text, token) >= 0)
            return token;
    }
    return "";
}

/**
 * Classify a resolver.
 * Returns one of: "public", "isp", "unknown".
 *  - "public"  : a known anycast/vendor resolver (exact IP or vendor ASN/org).
 *  - "isp"     : resolver matches a configured WAN DNS address; shared observations alone are inconclusive.
 *  - "unknown" : could not be classified with confidence.
 */
function classify_resolver(ip, name, asn, direct_map, wan_map) {
    ip = trim(as_string(ip || ""));
    if (ip != "" && KNOWN_PUBLIC_DNS_IPS[ip])
        return { kind: "public", vendor: KNOWN_PUBLIC_DNS_IPS[ip] };
    if (ip != "" && YANDEX_DNS_IPS[ip])
        return { kind: "public", vendor: "yandex" };

    if (ip != "" && wan_map && wan_map[ip])
        return { kind: "isp", vendor: "" };

    let vendor = vendor_matches(asn) || vendor_matches(name);
    if (vendor != "")
        return { kind: "public", vendor: vendor };

    if (ip != "" && direct_map && direct_map[ip])
        return { kind: "shared", vendor: "" };

    return { kind: "unknown", vendor: "" };
}


/**
 * Detect active WAN network interface/device name.
 * Prioritizes actual routing table default gateway device (e.g. pppoe-wan, eth1, br-wan),
 * avoiding IP-less physical interfaces from UCI network.wan.device under PPPoE/VLANs.
 */
function is_virtual_or_tunnel_iface(dev) {
    dev = trim(as_string(dev));
    if (dev == "" || dev == "lo")
        return true;
    if (match(dev, /^(tun|tap|tailscale|wg|docker|veth|br-|dummy|gre|sit|ifb)/))
        return true;
    return false;
}

function get_wan_interface() {
    // 1. Prefer default routing table lookup: the device carrying the default route
    // is guaranteed to be the active L3 interface.
    let route_res = command_capture("ip -4 route show default 2>/dev/null");
    if (route_res && route_res.status == 0 && route_res.output != "") {
        for (let line in split(route_res.output, "\n")) {
            let m = match(line, /dev\s+([a-zA-Z0-9_\.\-]+)/);
            if (m && m[1] && !is_virtual_or_tunnel_iface(m[1]))
                return trim(as_string(m[1]));
        }
    }

    // 2. Fallback to UCI network inspection
    try {
        let cursor = uci_core.cursor();
        if (cursor) {
            cursor.load("network");
            let dev = cursor.get("network", "wan", "device") || cursor.get("network", "wan", "ifname");
            if (dev != null && dev != "" && !is_virtual_or_tunnel_iface(dev))
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
function get_direct_curl_argv(wan_iface) {
    let parts = [];
    if (wan_iface != null && wan_iface != "") {
        push(parts, "--interface");
        push(parts, as_string(wan_iface));
    }

    if (curl_supports_so_mark()) {
        let mark = constants.NFT_OUTBOUND_MARK || "0x08000000";
        push(parts, "--so-mark");
        push(parts, as_string(mark));
    }

    return parts;
}

function get_direct_curl_flags(wan_iface) {
    let argv = get_direct_curl_argv(wan_iface);
    let parts = [];
    for (let i = 0; i < length(argv); i += 2)
        push(parts, argv[i] + " " + shell_quote(argv[i + 1]));

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
 * Probe the direct WAN path and the proxy path concurrently.
 *
 * Returns { direct, proxy, proxy_listening, proxy_token_ok } where direct/proxy
 * are parsed IP responses (or a sentinel with ok=false). This is the single
 * source of truth for IP data; the DNS stage reuses the returned proxy token.
 */
function probe_ip_paths(wan_iface, mixed_port) {
    let direct_flags = get_direct_curl_flags(wan_iface);
    let proxy_flag = "--proxy http://127.0.0.1:" + mixed_port;
    let proxy_listening = is_tcp_port_listening(mixed_port);

    let direct = null;
    let proxy = null;

    let tmp_res = command_capture("mktemp -d /tmp/tachyon_leak_ip_XXXXXX 2>/dev/null");
    let work_dir = (tmp_res && tmp_res.status == 0) ? trim(as_string(tmp_res.output)) : "";

    let ip_chain = function(flags, out) {
        return sprintf("( curl -s -m 3 --connect-timeout 2 %s https://api.ip.sb/geoip || curl -s -m 3 --connect-timeout 2 %s https://ipwho.is/ || curl -s -m 2 --connect-timeout 2 %s 'https://api.ipify.org?format=json' || curl -s -m 2 --connect-timeout 2 %s https://cloudflare.com/cdn-cgi/trace ) > %s 2>/dev/null",
            flags, flags, flags, flags, out);
    };

    if (work_dir != "") {
        let cmd_direct = ip_chain(direct_flags, work_dir + "/direct.out");
        let cmd_proxy = proxy_listening ? ip_chain(proxy_flag, work_dir + "/proxy.out") : "true";
        system(sprintf("{ %s & %s & wait; } 2>/dev/null", cmd_direct, cmd_proxy));

        direct = parse_ip_response(fs.readfile(work_dir + "/direct.out"));
        if (proxy_listening)
            proxy = parse_ip_response(fs.readfile(work_dir + "/proxy.out"));

        system(sprintf("rm -rf %s 2>/dev/null", shell_quote(work_dir)));
    }

    if (direct == null)
        direct = fetch_ip_info(false, wan_iface, mixed_port);
    if (proxy == null && proxy_listening)
        proxy = fetch_ip_info(true, wan_iface, mixed_port);
    if (proxy == null)
        proxy = { ip: "—", country: "", country_code: "", city: "", isp: "", ok: false };

    return {
        direct: direct,
        proxy: proxy,
        proxy_listening: proxy_listening,
        direct_flags: direct_flags,
        proxy_flag: proxy_flag
    };
}

/** Only DNS observations are resolver evidence; client IP and conclusions are not. */
function filter_dns_records(records) {
    let result = [];
    let seen = {};
    if (type(records) != "array") return result;
    for (let r in records) {
        if (type(r) != "object" || r.type != "dns" || type(r.ip) != "string") continue;
        let addr = lc(trim(r.ip));
        if ((!ip_utils.valid_ipv4(addr, false, true) && !ip_utils.valid_ipv6(addr)) || seen[addr]) continue;
        seen[addr] = true;
        push(result, { type: "dns", ip: addr, country: r.country, country_name: r.country_name, name: r.name, asn: r.asn });
    }
    return result;
}

/** Configuration evidence, not a packet-level claim. Never expose URL paths or credentials. */
function dns_configuration_evidence(config) {
    let result = [];
    if (type(config) != "object" || type(config.dns) != "object") return result;
    for (let s in config.dns.servers || []) {
        if (type(s) != "object") continue;
        let protocol = as_string(s.type || "unknown");
        let host = as_string(s.server || "");
        if (match(host, /^[a-zA-Z0-9.:-]+$/) == null) host = "";
        push(result, {
            tag: as_string(s.tag || ""), protocol: protocol, server: host,
            encrypted: protocol == "https" || protocol == "tls" || protocol == "quic" || protocol == "h3",
            detour: as_string(s.detour || "")
        });
    }
    return result;
}

/** WAN-address matches are warnings; shared or unknown observations are inconclusive. */
function analyse_resolvers(resolvers, direct_map, wan_map, fallback_isp_label) {
    let servers = [];
    let leaked = false;
    let has_unknown = false;
    let seen = {};

    for (let r in filter_dns_records(resolvers)) {
        if (type(r) != "object" || !r.ip)
            continue;
        let ip = trim(as_string(r.ip));
        if (ip == "" || seen[ip])
            continue;
        seen[ip] = true;

        let cls = classify_resolver(ip, r.name, r.asn, direct_map, wan_map);
        let is_isp = (cls.kind == "isp");
        if (is_isp)
            leaked = true;
        if (cls.kind == "unknown" || cls.kind == "shared")
            has_unknown = true;

        push(servers, {
            ip: ip,
            country: as_string(r.country || r.country_name || ""),
            isp: as_string(r.name || r.asn || fallback_isp_label),
            is_isp: is_isp,
            is_public: cls.kind == "public",
            verdict: cls.kind
        });
    }

    return { servers: servers, leaked: leaked, has_unknown: has_unknown };
}

function ip_stage_result(paths) {
    let direct = paths.direct;
    let proxy = paths.proxy;
    let proxy_online = (proxy.ok && proxy.ip != "—");
    let is_direct_routing = (proxy_online && direct.ok && direct.ip != "—" && proxy.ip == direct.ip);

    return {
        leaked: is_direct_routing,
        direct_mode: is_direct_routing,
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
 * Unified diagnostic check for both IP and DNS leaks.
 *
 * Single implementation used by the CLI (`leak-check`, `ip-leak`, `dns-leak`)
 * and the async worker, so the three callers can no longer drift apart.
 *
 * `want` is a set of stages: { ip: bool, dns: bool } — defaults to both.
 */
function run_leak_check_stages(wan_iface, mixed_port, want, test_mode) {
    let plus = test_mode == "plus";
    mixed_port = mixed_port || common.get_mixed_port();
    wan_iface = wan_iface != null ? wan_iface : get_wan_interface();
    want = want || {};
    let want_ip = want.ip != false;
    let want_dns = want.dns != false;

    let direct_dns_servers = get_direct_dns_servers();
    let paths = probe_ip_paths(wan_iface, mixed_port);
    let ip_res = want_ip ? ip_stage_result(paths) : null;

    // A DNS "verdict" of proxy_online must mean the DNS stage actually reached
    // the proxy path, not merely that a token was issued.
    let dns_res = {
        dns_leaked: false,
        verdict: "unavailable",
        direct_ip: paths.direct.ip,
        proxy_ip: paths.proxy.ip,
        dns_servers: [],
        direct_dns_servers: [],
        proxy_online: false,
        service_reachable: true
    };

    if (!want_dns)
        return { ip_leak: ip_res, dns_leak: dns_res, timestamp: time() };

    let tmp_res = command_capture("mktemp -d /tmp/tachyon_leak_dns_XXXXXX 2>/dev/null");
    let work_dir = (tmp_res && tmp_res.status == 0) ? trim(as_string(tmp_res.output)) : "";

    let proxy_stage = { resolvers: [], token_ok: false, query_ok: false, service_reachable: true };
    let direct_stage = { resolvers: [], token_ok: false, query_ok: false, service_reachable: true };
    let router_stage = { resolvers: [], token_ok: false, query_ok: false, service_reachable: true };
    let generated_config = plus ? common.read_json_file("/etc/sing-box/config.json") : null;
    let wire_result = { status: "unavailable", scope: "wan_port_53", queries: 0 };
    let tls_result = { status: "unavailable", scope: "independent_doh_probe", tls_verified: false, dns_answer_valid: false };

    if (work_dir != "") {
        // Both token fetches in parallel, then both DNS bursts sequentially.
        let token_direct = sprintf("curl -s -m 3 --connect-timeout 2 %s https://bash.ws/id > %s/direct_id 2>/dev/null", paths.direct_flags, work_dir);
        let token_proxy = sprintf("curl -s -m 3 --connect-timeout 2 %s https://bash.ws/id > %s/proxy_id 2>/dev/null", paths.proxy_flag, work_dir);
        let token_router = plus ? sprintf("curl -s -m 3 --connect-timeout 2 %s https://bash.ws/id > %s/router_id 2>/dev/null", paths.direct_flags, work_dir) : "true";
        system(sprintf("{ %s & %s & %s & wait; } 2>/dev/null", token_direct, token_proxy, token_router));

        let direct_id = trim(as_string(fs.readfile(work_dir + "/direct_id") || ""));
        let proxy_id = trim(as_string(fs.readfile(work_dir + "/proxy_id") || ""));
        let router_id = trim(as_string(fs.readfile(work_dir + "/router_id") || ""));

        let run_stage = function(id, flags, tag, out_id, local_dns) {
            if (match(id, /^[a-zA-Z0-9-]{1,63}$/) == null) {
                out_id.id = "";
                return;
            }
            out_id.id = id;
            out_id.token_ok = true;
            let burst = "{ ";
            for (let i = 1; i <= 4; i++) {
                if (local_dns)
                    burst += common.background_command(common.command_from_args([
                        "dig", "@127.0.0.1", sprintf("%d.%s.bash.ws", i, id),
                        "A", "+time=2", "+tries=1", "+short"
                    ])) + " ";
                else
                    burst += sprintf("curl -s -m 2 %s http://%d.%s.bash.ws >/dev/null 2>&1 & ", flags, i, id);
            }
            burst += "wait; } 2>/dev/null";
            system(burst);
            system("sleep 1 2>/dev/null");
            let rf = work_dir + "/" + tag + "_res";
            let rs = command_capture(sprintf("curl -s -m 3 --connect-timeout 2 %s 'https://bash.ws/dnsleak/test/%s?json' > %s 2>/dev/null", flags, id, rf));
            if (rs && rs.status != 0)
                out_id.service_reachable = false;
            let text = fs.readfile(rf);
            if (text) {
                try {
                    let parsed = json(text);
                    if (type(parsed) == "array")
                        out_id.resolvers = filter_dns_records(parsed);
                } catch (e) {}
            }
            out_id.query_ok = length(out_id.resolvers) > 0;
        };

        run_stage(direct_id, paths.direct_flags, "direct_res", direct_stage);
        run_stage(proxy_id, paths.proxy_flag, "proxy_res", proxy_stage);
        if (plus) {
            let capture = transport.capture_start(wan_iface, router_id, work_dir);
            run_stage(router_id, paths.direct_flags, "router_res", router_stage, true);
            wire_result = transport.capture_finish(capture, router_id, router_stage.query_ok);
            tls_result = transport.check_doh(generated_config, router_id, work_dir);
        }

        system(sprintf("rm -rf %s 2>/dev/null", shell_quote(work_dir)));
    }

    dns_res.service_reachable = proxy_stage.service_reachable && direct_stage.service_reachable;

    // Keep configured WAN addresses distinct from observed direct-path resolvers.
    let direct_map = {};
    let wan_map = {};
    for (let s in direct_dns_servers) {
        if (s.ip) {
            direct_map[s.ip] = true;
            wan_map[s.ip] = true;
        }
    }
    for (let r in direct_stage.resolvers) {
        if (type(r) == "object" && r.ip)
            direct_map[r.ip] = true;
    }

    let proxy_analysis = analyse_resolvers(proxy_stage.resolvers, direct_map, wan_map, "Unknown");
    let direct_analysis = analyse_resolvers(direct_stage.resolvers, direct_map, wan_map, "ISP Upstream");

    let formatted_proxy = proxy_analysis.servers;
    let formatted_direct = direct_analysis.servers;
    // Configured WAN DNS is not an observed resolver and must not replace missing test data.

    // proxy_online in the DNS context means: the proxy path actually produced a
    // resolver list. A token alone is not proof the queries traversed the proxy.
    let dns_proxy_online = proxy_stage.query_ok;

    if (!dns_res.service_reachable) {
        dns_res.verdict = "service_unreachable";
    } else if (!dns_proxy_online) {
        dns_res.verdict = "no_data";
    } else if (proxy_analysis.leaked) {
        dns_res.verdict = "leaked";
        dns_res.dns_leaked = true;
    } else if (proxy_analysis.has_unknown) {
        dns_res.verdict = "inconclusive";
    } else {
        dns_res.verdict = "secure";
    }

    dns_res.dns_servers = formatted_proxy;
    dns_res.direct_dns_servers = formatted_direct;
    dns_res.proxy_online = dns_proxy_online;
    if (plus) {
        let router_analysis = analyse_resolvers(router_stage.resolvers, direct_map, wan_map, "Unknown");
        dns_res.router_dns_servers = router_analysis.servers;
        dns_res.router_dns_status = !router_stage.token_ok || !router_stage.service_reachable ? "service_unreachable" : router_stage.query_ok ? "observed" : "no_data";
        dns_res.proxy_verdict = dns_res.verdict;
        if (dns_res.verdict == "secure" && (!router_stage.query_ok || router_analysis.has_unknown || router_analysis.leaked))
            dns_res.verdict = "inconclusive";
        dns_res.configured_dns = dns_configuration_evidence(generated_config);
        dns_res.wan_dns_capture = wire_result;
        dns_res.doh_tls_probe = tls_result;
        if (wire_result.status == "plaintext_observed") {
            dns_res.dns_leaked = true;
            dns_res.verdict = "plaintext_observed";
        } else if (dns_res.verdict == "secure" && (wire_result.status != "not_observed" ||
            tls_result.status != "verified" || tls_result.router_verification_disabled)) {
            dns_res.verdict = "inconclusive";
        }
    }

    return {
        mode: plus ? "plus" : "default",
        ip_leak: ip_res,
        dns_leak: dns_res,
        timestamp: time()
    };
}

/**
 * Full unified check (IP + DNS). Kept as the stable entry point used elsewhere.
 */
function run_leak_check(wan_iface, mixed_port, test_mode) {
    return run_leak_check_stages(wan_iface, mixed_port, { ip: true, dns: true }, test_mode);
}

/**
 * IP-only check (public API used by the CLI `ip-leak` command).
 */
function check_ip_leak(wan_iface, mixed_port) {
    let paths = probe_ip_paths(
        wan_iface != null ? wan_iface : get_wan_interface(),
        mixed_port || common.get_mixed_port()
    );
    return ip_stage_result(paths);
}

/**
 * DNS-only check (public API used by the CLI `dns-leak` command).
 */
function check_dns_leak(wan_iface, mixed_port, direct_ip, proxy_ip) {
    let res = run_leak_check_stages(
        wan_iface != null ? wan_iface : get_wan_interface(),
        mixed_port || common.get_mixed_port(),
        { ip: false, dns: true }
    );
    return res.dns_leak;
}


/**
 * Start asynchronous leak check job and return job_id.
 */
function start_leak_check_async(test_mode) {
    test_mode = test_mode == "plus" ? "plus" : "default";
    common.ensure_dir("/var/run/tachyon");
    common.ensure_dir(LEAK_JOB_DIR);

    let id = sprintf("%d_%d", time(), int(clock()[1] % 10000));
    let path = sprintf("%s/%s.json", LEAK_JOB_DIR, id);

    let initial_state = {
        running: true,
        job_id: id,
        progress: 25,
        stage: "ip",
        mode: test_mode,
        started_at: time()
    };

    if (!common.write_json_file(path, initial_state)) {
        print(sprintf("%J\n", { success: false, error: "Failed to initialize leak check job state" }));
        exit(1);
    }

    let lib_dir = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
    let mod_file = lib_dir + "/diagnostics/leak_check.uc";
    let worker_cmd = sprintf("TACHYON_LIB=%s ucode -L %s %s leak-check-worker %s %s", shell_quote(lib_dir), shell_quote(lib_dir), shell_quote(mod_file), shell_quote(id), shell_quote(test_mode));

    let bg_cmd = common.background_command_with_pid(worker_cmd);
    command_capture("sh -c " + shell_quote(bg_cmd));

    print(sprintf("%J\n", { success: true, job_id: id }));
    exit(0);
}

/**
 * Worker executing leak check in background and recording final state.
 */
function leak_check_worker(job_id, test_mode) {
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
        mode: test_mode,
        started_at: time()
    });

    let res = run_leak_check(null, null, test_mode);

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

    // Plus allows extra time for bounded capture and TLS probes.
    if (state.running && (time() - state.started_at > (state.mode == "plus" ? 60 : 40))) {
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
        if (res.ip_leak.proxy_ip == res.ip_leak.direct_ip) {
            print("IP Status     : ℹ️ DIRECT (WAN IP matches; normal under selective routing)\n");
        } else {
            print("IP Status     : ✅ SECURE (Real WAN IP is concealed behind proxy)\n");
        }
    } else {
        print("IP Status     : ⚪ Proxy is offline or unreachable\n");
    }

    print("\n--- DNS Resolvers Detected ---\n");
    if (res.dns_leak.proxy_online && length(res.dns_leak.dns_servers) > 0) {
        for (let s in res.dns_leak.dns_servers) {
            let flag = s.is_isp ? "⚠️ WAN DNS" : s.is_public ? "PUBLIC DNS" : "UNCONFIRMED";
            print(sprintf("  [%s] %s (%s - %s)\n", flag, s.ip, s.country, s.isp));
        }
    } else {
        print("  (No proxy DNS queries recorded or proxy offline)\n");
    }

    if (res.dns_leak.verdict == "plaintext_observed") {
        print("\nDNS Status    : Test DNS queries observed unencrypted on the selected WAN interface\n\n");
    } else if (!res.dns_leak.proxy_online) {
        print("\nDNS Status    : ⚪ Proxy offline (DNS check skipped)\n\n");
    } else if (res.dns_leak.dns_leaked) {
        print("\nDNS Status    : Resolver matches configured WAN DNS; evaluate the intended routing policy\n\n");
    } else if (res.dns_leak.verdict == "inconclusive") {
        print("\nDNS Status    : UNCONFIRMED (Insufficient resolver evidence; encryption is not verified)\n\n");
    } else {
        print("\nDNS Status    : No WAN-assigned resolver observed; encryption is not verified by this test\n\n");
    }
}

// --- CLI Dispatcher ---
let mode = ARGV[0] || "";
let test_mode = ARGV[1] == "plus" || ARGV[2] == "plus" ? "plus" : "default";

if (mode == "leak-check" || mode == "leak_check") {
    let res = run_leak_check(null, null, test_mode);
    if (ARGV[1] == "--pretty" || ARGV[1] == "-p" || ARGV[2] == "--pretty" || ARGV[2] == "-p") {
        print_cli_summary(res);
    } else {
        print(sprintf("%J\n", res));
    }
    exit(0);
}
else if (mode == "leak-check-async" || mode == "leak_check_async") {
    start_leak_check_async(test_mode);
}
else if (mode == "leak-check-worker") {
    leak_check_worker(ARGV[1], ARGV[2]);
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
    filter_dns_records,
    analyse_resolvers,
    dns_configuration_evidence,
    get_wan_interface,
    get_direct_dns_servers,
    get_direct_curl_flags,
    get_direct_curl_argv,
    fetch_ip_info,
    check_ip_leak,
    check_dns_leak,
    run_leak_check,
    start_leak_check_async,
    get_leak_check_status
};
