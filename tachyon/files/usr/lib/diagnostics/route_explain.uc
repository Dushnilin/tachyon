#!/usr/bin/env ucode

// ─── Tachyon Route Decision Explainer ─────────────────────────────────────────
//
// Traces the complete packet lifecycle and routing decision pipeline:
//   Client IP/MAC
//   → Device Section & Profiles
//   → Domain / IP Classification
//   → UCI Section & Rule Matching
//   → DNS Resolution Decision (FakeIP vs Tachyon DNS vs Direct)
//   → nftables Interception & fwmark (inet TachyonTable)
//   → Policy Routing Table (table 100 / ip rule)
//   → Core Engine (sing-box / steer)
//   → Outbound Group & Selected Node
//
// Provides machine-readable structured JSON and rich human-readable/AI explanations.

let fs = require("fs");
let common = require("core.common");
let constants = require("core.constants");
let core_ip = require("core.ip");
let uci_core = require("core.uci");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || constants.TACHYON_CONFIG_NAME || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const NFT_TABLE_NAME = getenv("NFT_TABLE_NAME") || constants.NFT_TABLE_NAME || "TachyonTable";
const RT_TABLE_NAME = getenv("RT_TABLE_NAME") || constants.RT_TABLE_NAME || "tachyon";
const NFT_FAKEIP_MARK = getenv("NFT_FAKEIP_MARK") || constants.NFT_FAKEIP_MARK || "0x04000000";
const SB_TPROXY_INBOUND_PORT = getenv("SB_TPROXY_INBOUND_PORT") || constants.SB_TPROXY_INBOUND_PORT || "1602";

let as_string = common.as_string;

// ─── IPv4 / IPv6 Subnet Helpers ──────────────────────────────────────────────

function ipv4_to_int(ip_str) {
    let parts = split(as_string(ip_str), ".");
    if (length(parts) != 4) return null;
    let a = int(parts[0]);
    let b = int(parts[1]);
    let c = int(parts[2]);
    let d = int(parts[3]);
    if (a < 0 || a > 255 || b < 0 || b > 255 || c < 0 || c > 255 || d < 0 || d > 255) return null;
    return (a * 16777216) + (b * 65536) + (c * 256) + d;
}

function ipv4_in_cidr(ip_str, cidr_str) {
    cidr_str = trim(as_string(cidr_str));
    let slash = index(cidr_str, "/");
    let net_ip = slash >= 0 ? substr(cidr_str, 0, slash) : cidr_str;
    let mask_bits = slash >= 0 ? int(substr(cidr_str, slash + 1)) : 32;
    if (mask_bits < 0 || mask_bits > 32) return false;

    let ip_num = ipv4_to_int(ip_str);
    let net_num = ipv4_to_int(net_ip);
    if (ip_num == null || net_num == null) return false;
    if (mask_bits == 0) return true;

    let shift = 32 - mask_bits;
    let div = 1;
    for (let i = 0; i < shift; i++) {
        div = div * 2;
    }
    return int(ip_num / div) == int(net_num / div);
}

function is_private_ipv4(ip_str) {
    if (!core_ip.valid_ipv4(ip_str, false, false)) return false;
    let priv_ranges = [
        "127.0.0.0/8",
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "169.254.0.0/16",
        "224.0.0.0/4",
        "240.0.0.0/4",
        "0.0.0.0/8"
    ];
    for (let cidr in priv_ranges) {
        if (ipv4_in_cidr(ip_str, cidr)) return true;
    }
    return false;
}

function is_fakeip_ipv4(ip_str) {
    return ipv4_in_cidr(ip_str, "198.18.0.0/15");
}

function is_private_ipv6(ip_str) {
    ip_str = lc(trim(as_string(ip_str)));
    if (!core_ip.valid_ipv6(ip_str)) return false;
    if (ip_str == "::" || ip_str == "::1") return true;
    if (substr(ip_str, 0, 4) == "fe80" || substr(ip_str, 0, 2) == "ff") return true;
    if (substr(ip_str, 0, 2) == "fc" || substr(ip_str, 0, 2) == "fd") return true;
    return false;
}

function is_private_ip(ip_str) {
    return is_private_ipv4(ip_str) || is_private_ipv6(ip_str);
}

// ─── Target Extraction & Normalization ────────────────────────────────────────

function normalize_target_input(raw_target) {
    let t = trim(as_string(raw_target));
    if (t == "") return { host: "", port: 0, proto: "tcp" };

    let proto = "tcp";
    let port = 0;

    // Strip scheme if present (e.g. https://domain.com:8443/path)
    let scheme_idx = index(t, "://");
    if (scheme_idx >= 0) {
        let scheme = lc(substr(t, 0, scheme_idx));
        if (scheme == "http") { port = 80; proto = "tcp"; }
        else if (scheme == "https") { port = 443; proto = "tcp"; }
        else if (scheme == "dns") { port = 53; proto = "udp"; }
        t = substr(t, scheme_idx + 3);
    }

    // Strip path and query if present
    let slash_idx = index(t, "/");
    if (slash_idx >= 0) {
        t = substr(t, 0, slash_idx);
    }
    let query_idx = index(t, "?");
    if (query_idx >= 0) {
        t = substr(t, 0, query_idx);
    }

    // Extract port from host:port if not IPv6
    if (index(t, "[") == 0) {
        let close_bracket = index(t, "]");
        if (close_bracket > 0) {
            let host_part = substr(t, 1, close_bracket - 1);
            let rest = substr(t, close_bracket + 1);
            if (index(rest, ":") == 0) {
                let p = int(substr(rest, 1));
                if (p > 0 && p <= 65535) port = p;
            }
            t = host_part;
        }
    } else {
        let colon_idx = index(t, ":");
        if (colon_idx > 0 && index(substr(t, colon_idx + 1), ":") < 0) {
            let p = int(substr(t, colon_idx + 1));
            if (p > 0 && p <= 65535) port = p;
            t = substr(t, 0, colon_idx);
        }
    }

    // Strip leading wildcard *. or .
    if (substr(t, 0, 2) == "*.") {
        t = substr(t, 2);
    } else if (substr(t, 0, 1) == ".") {
        t = substr(t, 1);
    }

    // Strip trailing dot
    if (length(t) > 0 && substr(t, length(t) - 1, 1) == ".") {
        t = substr(t, 0, length(t) - 1);
    }

    t = lc(t);
    return { host: t, port: port, proto: proto };
}

// ─── Domain Pattern Matchers ──────────────────────────────────────────────────

function domain_matches_exact(target_domain, pattern) {
    target_domain = lc(trim(as_string(target_domain)));
    pattern = lc(trim(as_string(pattern)));
    if (substr(pattern, 0, 2) == "*.") pattern = substr(pattern, 2);
    else if (substr(pattern, 0, 1) == ".") pattern = substr(pattern, 1);
    return target_domain == pattern;
}

function domain_matches_suffix(target_domain, suffix) {
    target_domain = lc(trim(as_string(target_domain)));
    suffix = lc(trim(as_string(suffix)));
    if (suffix == "") return false;
    if (substr(suffix, 0, 2) == "*.") suffix = substr(suffix, 2);
    else if (substr(suffix, 0, 1) == ".") suffix = substr(suffix, 1);

    if (target_domain == suffix) return true;
    let dot_suffix = "." + suffix;
    let s_len = length(dot_suffix);
    let t_len = length(target_domain);
    if (t_len < s_len) return false;
    return substr(target_domain, t_len - s_len) == dot_suffix;
}

function domain_matches_keyword(target_domain, keyword) {
    target_domain = lc(trim(as_string(target_domain)));
    keyword = lc(trim(as_string(keyword)));
    if (keyword == "") return false;
    return index(target_domain, keyword) >= 0;
}

function domain_matches_regex(target_domain, pattern) {
    target_domain = trim(as_string(target_domain));
    pattern = trim(as_string(pattern));
    if (pattern == "") return false;
    try {
        let r = match(target_domain, pattern);
        return r != null;
    } catch (e) {
        return false;
    }
}

// ─── Community Services Catalog ───────────────────────────────────────────────

const KNOWN_COMMUNITY_DOMAINS = {
    telegram: [ "t.me", "telegram.org", "telegram.me", "telesco.pe", "tdesktop.com", "telegra.ph" ],
    discord: [ "discord.com", "discord.gg", "discordapp.com", "discordapp.net", "discordstatus.com", "watchanimeattheoffice.net", "discord-attachments-uploads-prd.storage.googleapis.com" ],
    meta: [ "facebook.com", "instagram.com", "whatsapp.com", "fbcdn.net", "cdninstagram.com", "meta.com", "threads.net", "messenger.com" ],
    twitter: [ "twitter.com", "x.com", "twimg.com", "t.co", "x.co" ],
    youtube: [ "youtube.com", "googlevideo.com", "ytimg.com", "youtu.be", "ggpht.com" ],
    roblox: [ "roblox.com", "rbxcdn.com", "robloxlabs.com" ],
    cloudflare: [ "cloudflare.com", "cloudflare-dns.com", "workers.dev" ]
};

const KNOWN_COMMUNITY_SUBNETS = {
    telegram: [
        "91.108.4.0/22", "91.108.8.0/22", "91.108.12.0/22", "91.108.16.0/22",
        "91.108.20.0/22", "91.108.56.0/22", "149.154.160.0/20", "185.76.151.0/24"
    ],
    discord: [
        "162.158.0.0/15"
    ],
    meta: [
        "157.240.0.0/16", "31.13.64.0/18", "129.134.0.0/16", "185.60.216.0/22"
    ],
    cloudflare: [
        "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22",
        "141.101.64.0/18", "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20",
        "197.234.240.0/22", "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13",
        "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22"
    ]
};

function check_community_domain_match(target_domain, community_name) {
    community_name = lc(trim(as_string(community_name)));
    let domains = KNOWN_COMMUNITY_DOMAINS[community_name];
    if (type(domains) == "array") {
        for (let d in domains) {
            if (domain_matches_suffix(target_domain, d)) {
                return true;
            }
        }
    }
    // Also check direct substring of service name
    if (index(target_domain, community_name) >= 0) {
        return true;
    }
    return false;
}

function check_community_ip_match(target_ip, community_name) {
    community_name = lc(trim(as_string(community_name)));
    let subnets = KNOWN_COMMUNITY_SUBNETS[community_name];
    if (type(subnets) == "array") {
        for (let cidr in subnets) {
            if (ipv4_in_cidr(target_ip, cidr)) {
                return true;
            }
        }
    }
    // Also check local compiled ruleset list file if exists
    let subnets_file = "/usr/share/tachyon/rulesets/community-subnets-" + community_name + ".lst";
    let data = fs.readfile(subnets_file);
    if (data != null) {
        for (let line in split(as_string(data), "\n")) {
            line = trim(line);
            if (line != "" && index(line, "#") < 0) {
                if (ipv4_in_cidr(target_ip, line)) {
                    return true;
                }
            }
        }
    }
    return false;
}

// ─── Client / Device Classification ──────────────────────────────────────────

function classify_client(client_in, uci_cfg) {
    let raw = trim(as_string(client_in));
    let settings = uci_cfg.settings || {};
    let excluded_raw = settings.excluded_clients || settings.excluded_ips || [];
    let excluded_list = [];
    if (type(excluded_raw) == "string") {
        for (let w in split(excluded_raw, /[ \t,]+/)) {
            if (w != "") push(excluded_list, lc(trim(w)));
        }
    } else if (type(excluded_raw) == "array") {
        for (let item in excluded_raw) {
            let str = lc(trim(as_string(item)));
            if (str != "") push(excluded_list, str);
        }
    }

    let is_mac = core_ip.valid_mac(raw);
    let is_ip = core_ip.valid_ip(raw);
    let resolved_ips = [];
    let client_mac = is_mac ? lc(raw) : null;
    let client_ip = is_ip ? raw : null;

    if (is_mac) {
        resolved_ips = core_ip.resolve_mac_to_ips(client_mac);
        if (length(resolved_ips) > 0) {
            client_ip = resolved_ips[0];
        }
    }

    // Check if client is router itself
    let is_router = (raw == "127.0.0.1" || raw == "::1" || raw == "router" || raw == "local");

    // Check if client is in exclusion list
    let is_excluded = false;
    let exclusion_match = null;
    for (let exc in excluded_list) {
        if (client_ip != null && (exc == lc(client_ip) || ipv4_in_cidr(client_ip, exc))) {
            is_excluded = true;
            exclusion_match = exc;
            break;
        }
        if (client_mac != null && exc == client_mac) {
            is_excluded = true;
            exclusion_match = exc;
            break;
        }
        for (let res_ip in resolved_ips) {
            if (exc == lc(res_ip) || ipv4_in_cidr(res_ip, exc)) {
                is_excluded = true;
                exclusion_match = exc;
                break;
            }
        }
        if (is_excluded) break;
    }

    let client_type = "lan_client";
    if (is_router) client_type = "router_local";
    else if (is_excluded) client_type = "excluded";
    else if (raw == "") client_type = "default_lan";

    return {
        raw: raw,
        ip: client_ip || (is_router ? "127.0.0.1" : (raw != "" && is_ip ? raw : "192.168.1.100")),
        mac: client_mac,
        resolved_ips: resolved_ips,
        type: client_type,
        is_router: is_router,
        is_excluded: is_excluded,
        exclusion_match: exclusion_match
    };
}

// ─── UCI Configuration Loader ────────────────────────────────────────────────

function load_uci_tachyon_config() {
    let result = { settings: {}, sections: [], servers: [], dns_hosts: [] };
    let c = uci_core.cursor();
    if (!c) return result;
    try {
        c.load(CONFIG_NAME);
    } catch (e) {
        return result;
    }

    let raw_settings = c.get_all(CONFIG_NAME, "settings");
    if (type(raw_settings) == "object") {
        result.settings = raw_settings;
    }

    c.foreach(CONFIG_NAME, "section", function(s) {
        push(result.sections, s);
    });

    c.foreach(CONFIG_NAME, "server", function(s) {
        push(result.servers, s);
    });

    c.foreach(CONFIG_NAME, "dns_host", function(s) {
        push(result.dns_hosts, s);
    });

    return result;
}

// ─── Section Matching Engine ─────────────────────────────────────────────────

function parse_items_list(val) {
    if (val == null) return [];
    if (type(val) == "array") {
        let res = [];
        for (let item in val) {
            let s = trim(as_string(item));
            if (s != "") push(res, s);
        }
        return res;
    }
    let res = [];
    for (let part in split(as_string(val), /[ \t,\r\n]+/)) {
        part = trim(part);
        if (part != "") push(res, part);
    }
    return res;
}

function evaluate_section_match(section, client_info, target_info, port, proto) {
    if (section.enabled == "0") return null;

    // Check device restrictions on section if specified
    let dev_ips = parse_items_list(section.device_ip || section.devices || section.device_mac);
    if (length(dev_ips) > 0) {
        let dev_matched = false;
        for (let dev in dev_ips) {
            dev = lc(trim(dev));
            if (client_info.ip != null && (dev == lc(client_info.ip) || ipv4_in_cidr(client_info.ip, dev))) {
                dev_matched = true;
                break;
            }
            if (client_info.mac != null && dev == client_info.mac) {
                dev_matched = true;
                break;
            }
        }
        if (!dev_matched) return null;
    }

    // Check port restrictions on section if specified
    let ports = parse_items_list(section.ports || section.port);
    if (length(ports) > 0 && port > 0) {
        let port_matched = false;
        for (let p_spec in ports) {
            let dash = index(p_spec, "-");
            if (dash > 0) {
                let p_start = int(substr(p_spec, 0, dash));
                let p_end = int(substr(p_spec, dash + 1));
                if (port >= p_start && port <= p_end) {
                    port_matched = true;
                    break;
                }
            } else {
                if (int(p_spec) == port) {
                    port_matched = true;
                    break;
                }
            }
        }
        if (!port_matched) return null;
    }

    let is_domain = target_info.type == "domain";
    let is_ip = target_info.type == "ipv4" || target_info.type == "ipv6" || target_info.type == "cidr";

    // 1. Domain matching
    if (is_domain) {
        // Exact domain
        let domains = parse_items_list(section.domain);
        for (let d in domains) {
            if (domain_matches_exact(target_info.host, d)) {
                return { rule_type: "domain", rule_value: d };
            }
        }

        // Domain suffix
        let suffixes = parse_items_list(section.domain_suffix);
        for (let s in suffixes) {
            if (domain_matches_suffix(target_info.host, s)) {
                return { rule_type: "domain_suffix", rule_value: s };
            }
        }

        // Domain keyword
        let keywords = parse_items_list(section.domain_keyword);
        for (let kw in keywords) {
            if (domain_matches_keyword(target_info.host, kw)) {
                return { rule_type: "domain_keyword", rule_value: kw };
            }
        }

        // Domain regex
        let regexes = parse_items_list(section.domain_regex);
        for (let rx in regexes) {
            if (domain_matches_regex(target_info.host, rx)) {
                return { rule_type: "domain_regex", rule_value: rx };
            }
        }

        // Community lists
        let comm_lists = parse_items_list(section.community_lists || section.community);
        for (let comm in comm_lists) {
            if (check_community_domain_match(target_info.host, comm)) {
                return { rule_type: "community_list", rule_value: comm };
            }
        }

        // Rule set references
        let rule_sets = parse_items_list(section.rule_set);
        for (let rs in rule_sets) {
            if (check_community_domain_match(target_info.host, rs)) {
                return { rule_type: "rule_set", rule_value: rs };
            }
        }
    }

    // 2. IP matching
    if (is_ip) {
        let ip_cidrs = parse_items_list(section.ip_cidr || section.ip || section.subnets);
        for (let cidr in ip_cidrs) {
            if (ipv4_in_cidr(target_info.host, cidr)) {
                return { rule_type: "ip_cidr", rule_value: cidr };
            }
        }

        // Community subnets
        let comm_subnets = parse_items_list(section.community_subnets || section.community_lists || section.community);
        for (let comm in comm_subnets) {
            if (check_community_ip_match(target_info.host, comm)) {
                return { rule_type: "community_subnets", rule_value: comm };
            }
        }
    }

    return null;
}

// ─── Outbound Resolution ──────────────────────────────────────────────────────

function resolve_outbound_node(matched_section, matched_action, uci_cfg) {
    if (matched_action == "bypass" || matched_action == "direct") {
        return {
            group_tag: "bypass-out",
            group_type: "direct",
            selected_node: "Direct WAN Gateway",
            node_type: "direct",
            server_address: "WAN",
            server_port: 0,
            transport: "native"
        };
    }

    if (matched_action == "block") {
        return {
            group_tag: "block",
            group_type: "reject",
            selected_node: "Blackhole",
            node_type: "reject",
            server_address: "0.0.0.0",
            server_port: 0,
            transport: "none"
        };
    }

    if (matched_action == "zapret" || matched_action == "zapret2") {
        return {
            group_tag: "zapret-out",
            group_type: "nfqueue",
            selected_node: matched_action == "zapret2" ? "nfqws2-daemon" : "nfqws-daemon",
            node_type: "nfqueue",
            server_address: "127.0.0.1",
            server_port: 200,
            transport: "desync"
        };
    }

    if (matched_action == "byedpi") {
        return {
            group_tag: "byedpi-out",
            group_type: "socks5",
            selected_node: "ciadpi-daemon",
            node_type: "socks",
            server_address: "127.0.0.1",
            server_port: 1080,
            transport: "split"
        };
    }

    // Proxy action: resolve selector or server
    let sec_name = matched_section ? matched_section[".name"] : "default";
    let group_tag = sec_name + "-out";

    // 1. Check persistent selector state
    let selector_state = common.read_json_file("/etc/tachyon/selector_state.json") ||
                         common.read_json_file("/tmp/tachyon_selector_state.json") || {};
    let selected_tag = selector_state[group_tag] || selector_state[sec_name] || null;

    // 2. Check UCI servers for a matching server or default
    let servers = uci_cfg.servers || [];
    let found_server = null;

    if (selected_tag != null) {
        for (let s in servers) {
            if (s[".name"] == selected_tag || s.tag == selected_tag || s.label == selected_tag) {
                found_server = s;
                break;
            }
        }
    }

    // If not found by persistent choice, take server specified in section or first enabled server
    if (!found_server && matched_section && matched_section.outbound) {
        for (let s in servers) {
            if (s[".name"] == matched_section.outbound || s.tag == matched_section.outbound) {
                found_server = s;
                break;
            }
        }
    }

    if (!found_server && length(servers) > 0) {
        for (let s in servers) {
            if (s.enabled != "0") {
                found_server = s;
                break;
            }
        }
        if (!found_server) found_server = servers[0];
    }

    // 3. Fallback to active sing-box config if present
    if (!found_server) {
        let sb_config_raw = fs.readfile("/etc/sing-box/config.json");
        if (sb_config_raw) {
            try {
                let sb_cfg = json(sb_config_raw);
                for (let outb in (sb_cfg.outbounds || [])) {
                    if (outb.type != "direct" && outb.type != "dns" && outb.type != "block" && outb.type != "selector" && outb.type != "urltest") {
                        return {
                            group_tag: group_tag,
                            group_type: "selector",
                            selected_node: outb.tag || "Proxy-Node",
                            node_type: outb.type || "proxy",
                            server_address: outb.server || "unknown",
                            server_port: outb.server_port || 443,
                            transport: outb.tls ? (outb.tls.reality ? "reality" : "tls") : "plain"
                        };
                    }
                }
            } catch (e) {}
        }
    }

    let node_name = found_server ? (found_server.label || found_server.tag || found_server[".name"]) : "Default-Proxy-Node";
    let node_proto = found_server ? (found_server.type || found_server.proto || "vless") : "vless";
    let node_server = found_server ? (found_server.server || found_server.address || "remote.server.net") : "proxy.example.com";
    let node_port = found_server ? int(found_server.port || found_server.server_port || 443) : 443;
    let node_transport = "tls";
    if (found_server && (found_server.reality == "1" || found_server.tls == "reality")) node_transport = "reality";

    return {
        group_tag: group_tag,
        group_type: "selector",
        selected_node: node_name,
        node_type: node_proto,
        server_address: node_server,
        server_port: node_port,
        transport: node_transport
    };
}

// ─── Core Routing Explainer Implementation ────────────────────────────────────

function explain_route(client_in, target_in, port_in, proto_in, options) {
    options = options || {};
    let target_parsed = normalize_target_input(target_in);
    let target_host = target_parsed.host;
    if (target_host == "") {
        return {
            success: false,
            error: "Target host or destination address is required"
        };
    }

    let port = int(port_in || target_parsed.port);
    if (port <= 0 || port > 65535) {
        port = target_parsed.port > 0 ? target_parsed.port : 443;
    }
    let proto = lc(trim(as_string(proto_in || target_parsed.proto || "tcp")));
    if (proto == "") proto = "tcp";

    // Detect target type
    let target_type = "domain";
    if (core_ip.valid_ipv4(target_host, false, false)) target_type = "ipv4";
    else if (core_ip.valid_ipv4_cidr(target_host, false)) target_type = "cidr";
    else if (core_ip.valid_ipv6(target_host)) target_type = "ipv6";
    else if (core_ip.valid_ipv6_cidr(target_host)) target_type = "cidr";

    let target_info = {
        host: target_host,
        type: target_type,
        port: port,
        proto: proto,
        is_private: is_private_ip(target_host),
        is_fakeip: is_fakeip_ipv4(target_host)
    };

    let uci_cfg = load_uci_tachyon_config();
    let settings = uci_cfg.settings || {};
    let active_engine = settings.engine || "sing-box";
    let is_steer = active_engine == "steer" || active_engine == "steer-extended";
    let fakeip_enabled = settings.fakeip == "1";

    let client_info = classify_client(client_in, uci_cfg);

    // ─── Stage 1: Client Classification ───────────────────────────────────────
    let stage1 = {
        stage: 1,
        name: "client_classification",
        client: client_info.raw || client_info.ip,
        ip: client_info.ip,
        mac: client_info.mac,
        client_type: client_info.type,
        is_excluded: client_info.is_excluded,
        details: client_info.is_excluded
            ? "Client is explicitly excluded in Tachyon settings (matched: " + client_info.exclusion_match + ")."
            : (client_info.is_router
                ? "Traffic originates locally from router host (output chain)."
                : "Client is an active LAN host (prerouting chain).")
    };

    // ─── Stage 2: Target Classification ───────────────────────────────────────
    let stage2 = {
        stage: 2,
        name: "target_classification",
        target: target_info.host,
        target_type: target_info.type,
        port: port,
        proto: proto,
        is_private_ip: target_info.is_private,
        is_fakeip: target_info.is_fakeip,
        details: target_info.is_private
            ? "Target is a private/local RFC1918 address (in localv4 / localv6 set)."
            : (target_info.is_fakeip
                ? "Target is an active synthetic FakeIP in pool 198.18.0.0/15."
                : "Target is a public " + target_info.type + ".")
    };

    // Case A: Client is excluded -> Direct WAN
    if (client_info.is_excluded) {
        let verdict = "direct";
        let stage3 = {
            stage: 3,
            name: "section_matching",
            matched_section: null,
            rule_type: "client_bypass",
            rule_value: client_info.exclusion_match,
            action: "bypass",
            details: "Section matching skipped because client is in the exclusion list."
        };
        let stage4 = {
            stage: 4,
            name: "dns_decision",
            mode: "direct",
            resolver: "Local Upstream / ISP",
            details: "DNS queries from excluded client bypass Tachyon interception."
        };
        let stage5 = {
            stage: 5,
            name: "nftables_interception",
            table: NFT_TABLE_NAME,
            chain: "prerouting",
            intercepted: false,
            fwmark: "none",
            action: "accept",
            details: "Matched tachyon_bypass_clients set; accepted immediately without fwmark."
        };
        let stage6 = {
            stage: 6,
            name: "policy_routing",
            table: "main",
            ip_rule: "lookup main priority 32766",
            route: "default via WAN gateway dev wan",
            details: "Unmarked packet routed directly via kernel main routing table to WAN."
        };
        let stage7 = {
            stage: 7,
            name: "engine_outbound",
            engine: active_engine,
            engaged: false,
            outbound_tag: "direct",
            selected_node: "Native WAN",
            details: "Core proxy engine not engaged; line-rate native forwarding."
        };

        return {
            success: true,
            query: {
                client: client_info.raw || client_info.ip,
                target: target_info.host,
                port: port,
                proto: proto
            },
            verdict: verdict,
            matched_section: null,
            matched_rule: {
                type: "client_exclusion",
                value: client_info.exclusion_match,
                section: "settings",
                action: "bypass"
            },
            stages: {
                "1_client_classification": stage1,
                "2_target_classification": stage2,
                "3_section_matching": stage3,
                "4_dns_decision": stage4,
                "5_nftables_interception": stage5,
                "6_policy_routing": stage6,
                "7_engine_outbound": stage7
            },
            explanation: {
                en: "Client " + (client_info.raw || client_info.ip) + " is listed in excluded_clients. Traffic to " + target_info.host + ":" + port + " bypasses Tachyon at nftables prerouting and is routed directly to WAN.",
                ru: "Устройство " + (client_info.raw || client_info.ip) + " указано в списке исключений (excluded_clients). Трафик к " + target_info.host + ":" + port + " обходит прокси на этапе nftables prerouting и направляется напрямую в WAN."
            }
        };
    }

    // Case B: Target is Private IP -> Local LAN
    if (target_info.is_private) {
        let verdict = "local";
        let stage3 = {
            stage: 3,
            name: "section_matching",
            matched_section: null,
            rule_type: "private_ip",
            rule_value: target_info.host,
            action: "direct",
            details: "Target belongs to RFC1918 / local network space; proxy rules bypassed."
        };
        let stage4 = {
            stage: 4,
            name: "dns_decision",
            mode: "local",
            resolver: "LAN / dnsmasq",
            details: "Local IP address; no external DNS resolution required."
        };
        let stage5 = {
            stage: 5,
            name: "nftables_interception",
            table: NFT_TABLE_NAME,
            chain: "prerouting",
            intercepted: false,
            fwmark: "none",
            action: "return",
            details: "Matched @localv4 / @localv6 set; returned to kernel bridge/routing without mark."
        };
        let stage6 = {
            stage: 6,
            name: "policy_routing",
            table: "main",
            ip_rule: "lookup main priority 32766",
            route: "LAN subnet dev br-lan",
            details: "Local delivery directly across LAN bridge without tunneling."
        };
        let stage7 = {
            stage: 7,
            name: "engine_outbound",
            engine: active_engine,
            engaged: false,
            outbound_tag: "local",
            selected_node: "Local LAN",
            details: "Direct LAN switching / routing without proxy overhead."
        };

        return {
            success: true,
            query: {
                client: client_info.raw || client_info.ip,
                target: target_info.host,
                port: port,
                proto: proto
            },
            verdict: verdict,
            matched_section: null,
            matched_rule: {
                type: "local_ip",
                value: target_info.host,
                section: "localv4",
                action: "direct"
            },
            stages: {
                "1_client_classification": stage1,
                "2_target_classification": stage2,
                "3_section_matching": stage3,
                "4_dns_decision": stage4,
                "5_nftables_interception": stage5,
                "6_policy_routing": stage6,
                "7_engine_outbound": stage7
            },
            explanation: {
                en: "Target " + target_info.host + " is a private/local IP address in RFC1918 / localv4 set. Traffic is delivered directly over the LAN.",
                ru: "Целевой адрес " + target_info.host + " является приватным/локальным адресом (RFC1918 / сет localv4). Трафик передается напрямую в локальной сети."
            }
        };
    }

    // ─── Stage 3: Section & Rule Matching ─────────────────────────────────────
    let matched_section = null;
    let matched_rule = null;

    for (let sec in uci_cfg.sections) {
        let match_res = evaluate_section_match(sec, client_info, target_info, port, proto);
        if (match_res != null) {
            matched_section = sec;
            matched_rule = match_res;
            break;
        }
    }

    let section_name = matched_section ? matched_section[".name"] : null;
    let section_label = matched_section ? (matched_section.label || matched_section[".name"]) : null;
    let action = matched_section ? (matched_section.action || "outbound") : "direct";

    let stage3 = {
        stage: 3,
        name: "section_matching",
        matched_section: section_name,
        section_label: section_label,
        action: action,
        rule_type: matched_rule ? matched_rule.rule_type : "default_fallback",
        rule_value: matched_rule ? matched_rule.rule_value : "none",
        details: matched_section
            ? "Matched section '" + section_name + "' (" + action + ") by " + matched_rule.rule_type + " '" + matched_rule.rule_value + "'."
            : "No explicit section matched. Evaluated under default fallback routing rule."
    };

    // ─── Stage 4: DNS Resolution Decision ─────────────────────────────────────
    let dns_mode = "direct";
    let dns_resolver = "Upstream DNS";
    let dns_details = "";

    if (target_info.type == "domain") {
        if (action == "bypass" || action == "direct") {
            dns_mode = "direct";
            dns_resolver = "Standard Upstream / DoH";
            dns_details = "Domain is routed direct; resolved via standard system DNS forwarders.";
        } else if (action == "hosts") {
            dns_mode = "hosts";
            dns_resolver = "dnsmasq dns_hosts";
            dns_details = "Domain matches a static hosts override rule.";
        } else if (fakeip_enabled) {
            dns_mode = "fakeip";
            dns_resolver = "sing-box FakeIP (127.0.0.1:5353)";
            dns_details = "Domain resolved by sing-box FakeIP resolver. Synthetic IPv4 allocated in pool 198.18.0.0/15.";
        } else {
            dns_mode = "tachyon_dns";
            dns_resolver = "dnsmasq -> sing-box (127.0.0.1:5353)";
            dns_details = "Domain resolved via secure proxy DNS. dnsmasq automatically populates nftables set 'tachyon_target_v4' with resolved IP.";
        }
    } else {
        dns_mode = "none";
        dns_resolver = "none";
        dns_details = "Target provided as an IP address; DNS lookup skipped.";
    }

    let stage4 = {
        stage: 4,
        name: "dns_decision",
        mode: dns_mode,
        resolver: dns_resolver,
        fakeip_active: fakeip_enabled,
        details: dns_details
    };

    // ─── Stage 5: nftables Interception ───────────────────────────────────────
    let nft_intercepted = false;
    let nft_mark = "none";
    let nft_action = "accept";
    let nft_details = "";

    if (action == "bypass" || action == "direct") {
        nft_intercepted = false;
        nft_mark = "0x80000000";
        nft_action = "meta mark set 0x80000000 accept";
        nft_details = "Marked with bypass flag 0x80000000 and forwarded to WAN without proxy interception.";
    } else if (action == "block") {
        nft_intercepted = true;
        nft_mark = "none";
        nft_action = "reject with icmp type admin-prohibited";
        nft_details = "Blocked at firewall boundary by admin reject rule.";
    } else if (action == "zapret" || action == "zapret2") {
        nft_intercepted = true;
        nft_mark = "0x20000000";
        nft_action = "meta mark set 0x20000000 queue num 200 accept";
        nft_details = "Marked with 0x20000000 and diverted to NFQueue 200 for nfqws packet desynchronization.";
    } else if (action == "byedpi") {
        nft_intercepted = true;
        nft_mark = "0x40000000";
        nft_action = "meta mark set 0x40000000 redirect to :1080";
        nft_details = "Marked with 0x40000000 and redirected to local ByeDPI SOCKS proxy on port 1080.";
    } else {
        // Proxy action (sing-box / steer)
        nft_intercepted = true;
        nft_mark = NFT_FAKEIP_MARK;
        nft_action = "meta mark set " + NFT_FAKEIP_MARK + " tproxy to :" + SB_TPROXY_INBOUND_PORT + " accept";
        nft_details = "Diverted via TProxy on port " + SB_TPROXY_INBOUND_PORT + " with firewall mark " + NFT_FAKEIP_MARK + ".";
    }

    let stage5 = {
        stage: 5,
        name: "nftables_interception",
        table: NFT_TABLE_NAME,
        chain: client_info.is_router ? "output" : "prerouting",
        hook: client_info.is_router ? "output (-100)" : "prerouting priority dstnat (-100)",
        intercepted: nft_intercepted,
        fwmark: nft_mark,
        action: nft_action,
        details: nft_details
    };

    // ─── Stage 6: Policy Routing Table ────────────────────────────────────────
    let rt_table = "main";
    let rt_rule = "lookup main priority 32766";
    let rt_route = "default via WAN gateway dev wan";
    let rt_details = "";

    if (nft_intercepted && (nft_mark == NFT_FAKEIP_MARK || nft_mark == "0x10000000")) {
        rt_table = RT_TABLE_NAME + " (100)";
        rt_rule = "from all fwmark " + NFT_FAKEIP_MARK + "/" + NFT_FAKEIP_MARK + " lookup " + RT_TABLE_NAME + " priority 10000";
        rt_route = "local default dev lo table " + RT_TABLE_NAME;
        rt_details = "Fwmark matches policy rule; packet diverted to loopback (dev lo) so local TProxy socket can accept it.";
    } else {
        rt_table = "main";
        rt_rule = "from all lookup main priority 32766";
        rt_route = "default via WAN gateway";
        rt_details = "Standard Linux routing; packet forwarded directly over native interfaces.";
    }

    let stage6 = {
        stage: 6,
        name: "policy_routing",
        table: rt_table,
        ip_rule: rt_rule,
        route: rt_route,
        details: rt_details
    };

    // ─── Stage 7: Core Engine & Outbound Resolution ───────────────────────────
    let outbound_res = resolve_outbound_node(matched_section, action, uci_cfg);

    let stage7 = {
        stage: 7,
        name: "engine_outbound",
        engine: active_engine,
        inbound_tag: "tproxy-in",
        group_tag: outbound_res.group_tag,
        group_type: outbound_res.group_type,
        selected_node: outbound_res.selected_node,
        node_type: outbound_res.node_type,
        server_address: outbound_res.server_address,
        server_port: outbound_res.server_port,
        transport: outbound_res.transport,
        details: (action == "bypass" || action == "direct")
            ? "Engine forwards traffic directly to WAN via bypass-out."
            : (action == "block"
                ? "Engine drops traffic via reject action."
                : "Engine routes packet to outbound group '" + outbound_res.group_tag + "', selecting node '" + outbound_res.selected_node + "' (" + outbound_res.node_type + " / " + outbound_res.transport + ").")
    };

    // ─── Final Verdict & Explanations ─────────────────────────────────────────
    let verdict = "proxied";
    if (action == "bypass" || action == "direct") verdict = "direct";
    else if (action == "block") verdict = "blocked";
    else if (action == "zapret" || action == "zapret2") verdict = "zapret";
    else if (action == "byedpi") verdict = "byedpi";

    let rule_desc = matched_rule ? (matched_rule.rule_type + " '" + matched_rule.rule_value + "'") : "default rule";
    let client_str = client_info.raw || client_info.ip;

    let en_msg = "";
    let ru_msg = "";

    if (verdict == "proxied") {
        en_msg = "Traffic from " + client_str + " to " + target_info.host + ":" + port + " matches section '" + section_name + "' (" + rule_desc + "). Diverted via TProxy (" + NFT_FAKEIP_MARK + ") to " + active_engine + ". Routed to outbound group '" + outbound_res.group_tag + "', active node '" + outbound_res.selected_node + "' (" + outbound_res.node_type + ").";
        ru_msg = "Трафик от " + client_str + " к " + target_info.host + ":" + port + " совпадает с секцией «" + (section_label || section_name) + "» (" + rule_desc + "). Перехвачен через TProxy (" + NFT_FAKEIP_MARK + ") в " + active_engine + ". Направлен в группу «" + outbound_res.group_tag + "», активный узел: «" + outbound_res.selected_node + "» (" + outbound_res.node_type + ").";
    } else if (verdict == "direct") {
        en_msg = "Traffic from " + client_str + " to " + target_info.host + ":" + port + " is routed DIRECTLY to WAN (matched: " + (section_name ? ("section '" + section_name + "'") : "default direct") + ").";
        ru_msg = "Трафик от " + client_str + " к " + target_info.host + ":" + port + " направляется НАПРЯМУЮ в WAN (правило: " + (section_name ? ("секция «" + (section_label || section_name) + "»") : "прямой маршрут по умолчанию") + ").";
    } else if (verdict == "blocked") {
        en_msg = "Traffic from " + client_str + " to " + target_info.host + ":" + port + " is BLOCKED by section '" + section_name + "' (" + rule_desc + ").";
        ru_msg = "Трафик от " + client_str + " к " + target_info.host + ":" + port + " ЗАБЛОКИРОВАН секцией «" + (section_label || section_name) + "» (" + rule_desc + ").";
    } else if (verdict == "zapret") {
        en_msg = "Traffic from " + client_str + " to " + target_info.host + ":" + port + " matches DPI bypass section '" + section_name + "'. Diverted to NFQueue 200 for nfqws packet desynchronization.";
        ru_msg = "Трафик от " + client_str + " к " + target_info.host + ":" + port + " совпадает с секцией обхода DPI «" + (section_label || section_name) + "». Перенаправлен в NFQueue 200 для десинхронизации через nfqws.";
    } else if (verdict == "byedpi") {
        en_msg = "Traffic from " + client_str + " to " + target_info.host + ":" + port + " matches ByeDPI section '" + section_name + "'. Diverted to local ciadpi SOCKS proxy.";
        ru_msg = "Трафик от " + client_str + " к " + target_info.host + ":" + port + " совпадает с секцией ByeDPI «" + (section_label || section_name) + "». Перенаправлен в локальный прокси ciadpi.";
    }

    return {
        success: true,
        query: {
            client: client_str,
            client_mac: client_info.mac,
            target: target_info.host,
            target_type: target_info.type,
            port: port,
            proto: proto
        },
        verdict: verdict,
        matched_section: section_name,
        matched_rule: {
            type: matched_rule ? matched_rule.rule_type : "default_fallback",
            value: matched_rule ? matched_rule.rule_value : "none",
            section: section_name || "default",
            action: action
        },
        stages: {
            "1_client_classification": stage1,
            "2_target_classification": stage2,
            "3_section_matching": stage3,
            "4_dns_decision": stage4,
            "5_nftables_interception": stage5,
            "6_policy_routing": stage6,
            "7_engine_outbound": stage7
        },
        explanation: {
            en: en_msg,
            ru: ru_msg
        }
    };
}

// ─── Formatters & CLI Presentation ────────────────────────────────────────────

function format_text_report(report) {
    if (!report.success) {
        return "Route Explain Error: " + (report.error || "Unknown error") + "\n";
    }

    let q = report.query;
    let lines = [];
    push(lines, "══════════════════════════════════════════════════════════════════════════════");
    push(lines, "                    TACHYON ROUTE DECISION EXPLAINER                         ");
    push(lines, "══════════════════════════════════════════════════════════════════════════════");
    push(lines, sprintf(" Query:   Client %s -> Target %s:%d (%s)", q.client, q.target, q.port, q.proto));
    push(lines, sprintf(" Verdict: [%s] (Rule: %s:%s -> action '%s')",
        uc(report.verdict),
        report.matched_rule.type,
        report.matched_rule.value,
        report.matched_rule.action
    ));
    push(lines, "──────────────────────────────────────────────────────────────────────────────");
    push(lines, " Pipeline Journey:");

    let s1 = report.stages["1_client_classification"];
    push(lines, sprintf("  1. Client:      %s (%s) [Excluded: %s]", s1.client, s1.client_type, s1.is_excluded ? "YES" : "NO"));

    let s2 = report.stages["2_target_classification"];
    push(lines, sprintf("  2. Target:      %s (type: %s, private: %s)", s2.target, s2.target_type, s2.is_private_ip ? "YES" : "NO"));

    let s3 = report.stages["3_section_matching"];
    push(lines, sprintf("  3. Section:     %s (action: %s, rule: %s='%s')",
        s3.matched_section || "(none)", s3.action, s3.rule_type, s3.rule_value));

    let s4 = report.stages["4_dns_decision"];
    push(lines, sprintf("  4. DNS Mode:    %s (resolver: %s)", s4.mode, s4.resolver));

    let s5 = report.stages["5_nftables_interception"];
    push(lines, sprintf("  5. nftables:    Intercepted=%s (table: %s, mark: %s, action: %s)",
        s5.intercepted ? "YES" : "NO", s5.table, s5.fwmark, s5.action));

    let s6 = report.stages["6_policy_routing"];
    push(lines, sprintf("  6. Routing:     Table '%s' (%s)", s6.table, s6.route));

    let s7 = report.stages["7_engine_outbound"];
    push(lines, sprintf("  7. Engine:      %s -> Outbound Group '%s' -> Node '%s' (%s)",
        s7.engine, s7.group_tag, s7.selected_node, s7.node_type));

    push(lines, "──────────────────────────────────────────────────────────────────────────────");
    push(lines, " Explanation (RU):");
    push(lines, "  " + report.explanation.ru);
    push(lines, " Explanation (EN):");
    push(lines, "  " + report.explanation.en);
    push(lines, "══════════════════════════════════════════════════════════════════════════════");

    return join("\n", lines) + "\n";
}

// ─── Self-Test ────────────────────────────────────────────────────────────────

function selftest() {
    let passed = 0;
    let failed = 0;

    function assert(cond, name) {
        if (cond) {
            passed++;
        } else {
            failed++;
            warn("FAIL: " + name + "\n");
        }
    }

    // Test 1: IPv4 CIDR matching
    assert(ipv4_in_cidr("192.168.1.50", "192.168.1.0/24") == true, "ipv4 in /24 subnet");
    assert(ipv4_in_cidr("192.168.2.1", "192.168.1.0/24") == false, "ipv4 not in /24 subnet");
    assert(ipv4_in_cidr("10.5.20.1", "10.0.0.0/8") == true, "ipv4 in /8 subnet");
    assert(ipv4_in_cidr("198.18.5.12", "198.18.0.0/15") == true, "fakeip in /15 subnet");

    // Test 2: Private IP detection
    assert(is_private_ipv4("127.0.0.1") == true, "loopback is private");
    assert(is_private_ipv4("192.168.1.1") == true, "192.168.1.1 is private");
    assert(is_private_ipv4("10.0.0.1") == true, "10.0.0.1 is private");
    assert(is_private_ipv4("8.8.8.8") == false, "8.8.8.8 is public");
    assert(is_private_ipv4("1.1.1.1") == false, "1.1.1.1 is public");

    // Test 3: Domain matching
    assert(domain_matches_exact("instagram.com", "instagram.com") == true, "domain exact match");
    assert(domain_matches_exact("api.instagram.com", "instagram.com") == false, "domain exact mismatch");
    assert(domain_matches_suffix("api.instagram.com", "instagram.com") == true, "domain suffix match");
    assert(domain_matches_suffix("fakeinstagram.com", "instagram.com") == false, "domain suffix boundary check");
    assert(domain_matches_suffix("instagram.com", ".instagram.com") == true, "leading dot suffix");
    assert(domain_matches_keyword("my-instagram-app.com", "instagram") == true, "domain keyword match");

    // Test 4: Community matching
    assert(check_community_domain_match("t.me", "telegram") == true, "community telegram t.me");
    assert(check_community_domain_match("discord.gg", "discord") == true, "community discord discord.gg");
    assert(check_community_domain_match("instagram.com", "meta") == true, "community meta instagram.com");

    // Test 5: Target normalization
    let norm1 = normalize_target_input("https://instagram.com:8443/feed");
    assert(norm1.host == "instagram.com" && norm1.port == 8443, "normalize target URL with port");

    let norm2 = normalize_target_input("*.youtube.com.");
    assert(norm2.host == "youtube.com", "normalize wildcard and trailing dot");

    // Test 6: Route explanation for local IP
    let res_local = explain_route("192.168.1.100", "192.168.1.1", 80, "tcp");
    assert(res_local.success == true && res_local.verdict == "local", "local IP verdict is 'local'");
    assert(res_local.stages["5_nftables_interception"].intercepted == false, "local IP not intercepted in nftables");

    // Test 7: Route explanation for external domain with mock config
    let res_dom = explain_route("192.168.1.55", "instagram.com", 443, "tcp");
    assert(res_dom.success == true, "explain_route succeeds for domain");
    assert(res_dom.query.target == "instagram.com", "query target recorded");
    assert(res_dom.stages["1_client_classification"].stage == 1, "stage 1 exists");
    assert(res_dom.stages["7_engine_outbound"].stage == 7, "stage 7 exists");

    // Test 8: Formatter produces expected output
    let text = format_text_report(res_dom);
    assert(index(text, "TACHYON ROUTE DECISION EXPLAINER") >= 0, "text formatter header");
    assert(index(text, "instagram.com") >= 0, "text formatter includes target");

    print(sprintf("Route explain selftest: %d passed, %d failed\n", passed, failed));
    return failed == 0 ? 0 : 1;
}

// ─── Module Exports & CLI Handling ────────────────────────────────────────────

let mode = ARGV[0] || "";

if (mode == "selftest") {
    exit(selftest());
} else if (mode == "explain") {
    let client = ARGV[1] || "";
    let target = ARGV[2] || "";
    let port = ARGV[3] || 0;
    let proto = ARGV[4] || "tcp";
    let format = "text";

    // Check for --format flag in any argument position
    for (let i = 1; i < length(ARGV); i++) {
        if (ARGV[i] == "--format" && i + 1 < length(ARGV)) {
            format = ARGV[i + 1];
        } else if (ARGV[i] == "--json") {
            format = "json";
        }
    }

    let report = explain_route(client, target, port, proto);
    if (format == "json") {
        print(sprintf("%J\n", report));
    } else {
        print(format_text_report(report));
    }
    exit(report.success ? 0 : 1);
}

return {
    explain_route,
    format_text_report,
    normalize_target_input,
    classify_client,
    ipv4_in_cidr,
    is_private_ip,
    domain_matches_exact,
    domain_matches_suffix,
    domain_matches_keyword,
    domain_matches_regex,
    check_community_domain_match,
    check_community_ip_match,
    selftest
};
