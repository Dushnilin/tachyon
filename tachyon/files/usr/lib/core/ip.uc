#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let as_string = common.as_string;

function decimal_text(value, strict) {
    value = as_string(value);
    if (value == "" || match(value, /^[0-9]+$/) == null)
        return false;
    return !strict || length(value) == 1 || substr(value, 0, 1) != "0";
}

function valid_ipv4(value, allow_trailing_dot, strict_decimal) {
    value = as_string(value);
    if (allow_trailing_dot && length(value) > 0 && substr(value, length(value) - 1, 1) == ".")
        value = substr(value, 0, length(value) - 1);

    let parts = split(value, ".");
    if (length(parts) != 4)
        return false;

    for (let part in parts) {
        if (!decimal_text(part, strict_decimal))
            return false;

        let octet = int(part);
        if (octet < 0 || octet > 255)
            return false;
    }

    return true;
}

function valid_ipv4_cidr(value, strict_decimal) {
    value = as_string(value);
    let slash = index(value, "/");
    if (slash <= 0 || index(substr(value, slash + 1), "/") >= 0)
        return false;

    let prefix = substr(value, slash + 1);
    if (!decimal_text(prefix, strict_decimal))
        return false;

    let prefix_number = int(prefix);
    return valid_ipv4(substr(value, 0, slash), false, strict_decimal) && prefix_number >= 0 && prefix_number <= 32;
}

function valid_ipv6_hextet(value) {
    value = as_string(value);
    return value != "" && length(value) <= 4 && match(value, /^[0-9A-Fa-f]+$/) != null;
}

function ipv6_parts_count(parts) {
    let count = 0;

    for (let i = 0; i < length(parts); i++) {
        let part = parts[i];
        if (part == "")
            return -1;

        if (index(part, ".") >= 0) {
            if (i != length(parts) - 1 || !valid_ipv4(part, false, false))
                return -1;
            count += 2;
            continue;
        }

        if (!valid_ipv6_hextet(part))
            return -1;
        count++;
    }

    return count;
}

function valid_ipv6(value) {
    value = as_string(value);
    if (value == "" || index(value, "/") >= 0 || index(value, "%") >= 0)
        return false;

    let marker = index(value, "::");
    if (marker >= 0) {
        if (index(substr(value, marker + 2), "::") >= 0)
            return false;

        let left = substr(value, 0, marker);
        let right = substr(value, marker + 2);
        let left_count = left == "" ? 0 : ipv6_parts_count(split(left, ":"));
        let right_count = right == "" ? 0 : ipv6_parts_count(split(right, ":"));

        return left_count >= 0 && right_count >= 0 && left_count + right_count < 8;
    }

    let count = ipv6_parts_count(split(value, ":"));
    return count == 8;
}

function valid_ipv6_cidr(value) {
    value = as_string(value);
    let slash = index(value, "/");
    if (slash <= 0 || index(substr(value, slash + 1), "/") >= 0)
        return false;

    let prefix = substr(value, slash + 1);
    if (!decimal_text(prefix, false))
        return false;

    let prefix_number = int(prefix);
    return valid_ipv6(substr(value, 0, slash)) && prefix_number >= 0 && prefix_number <= 128;
}

function valid_ip(value) {
    return valid_ipv4(value, false, false) || valid_ipv6(value);
}

function valid_ip_cidr(value) {
    return valid_ipv4_cidr(value, false) || valid_ipv6_cidr(value);
}

function valid_ip_or_cidr(value) {
    return valid_ip(value) || valid_ip_cidr(value);
}

function nft_ip_or_cidr(value) {
    return valid_ipv4(value, true, true) || valid_ipv4_cidr(value, true) || valid_ipv6(value) || valid_ipv6_cidr(value);
}

function ip_family(value) {
    return valid_ipv4(value, false, false) || valid_ipv4_cidr(value, false) ? 4 :
        (valid_ipv6(value) || valid_ipv6_cidr(value) ? 6 : 0);
}

function format_ipv6_tproxy_target(address, port) {
    address = as_string(address);
    if (index(address, "]:") >= 0)
        return address;
    if (substr(address, 0, 1) == "[" && substr(address, length(address) - 1, 1) == "]")
        return address + ":" + as_string(port);
    return "[" + address + "]:" + as_string(port);
}

function ipv6_supported() {
    return common.ipv6_supported();
}

function valid_mac(value) {
    value = trim(as_string(value));
    return match(value, /^([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}$/) != null;
}

function resolve_mac_to_ips(mac) {
    mac = lc(replace(trim(as_string(mac)), "-", ":"));
    if (mac == "")
        return [];
    let matched = [];
    let seen = {};

    let lease_files = [ "/tmp/dhcp.leases", "/var/lib/misc/dnsmasq.leases", "/tmp/hosts/dhcp", "/tmp/hosts/odhcpd", "/var/run/odhcpd.leases" ];
    for (let lpath in lease_files) {
        let data = fs.readfile(lpath);
        if (!data)
            continue;
        for (let line in split(as_string(data), "\n")) {
            line = trim(line);
            if (line == "" || index(line, "#") == 0)
                continue;
            let fields = split(line, /[ \t]+/);
            if (length(fields) >= 3) {
                let m = lc(replace(fields[1], "-", ":"));
                let ip = fields[2];
                if (m == mac && valid_ip(ip) && !seen[ip]) {
                    seen[ip] = true;
                    push(matched, ip);
                }
            }
        }
    }

    let arp_data = fs.readfile("/proc/net/arp");
    if (arp_data) {
        for (let line in split(as_string(arp_data), "\n")) {
            line = trim(line);
            if (line == "" || index(line, "IP address") == 0)
                continue;
            let fields = split(line, /[ \t]+/);
            if (length(fields) >= 4) {
                let ip = fields[0];
                let m = lc(replace(fields[3], "-", ":"));
                if (m == mac && valid_ip(ip) && !seen[ip]) {
                    seen[ip] = true;
                    push(matched, ip);
                }
            }
        }
    }

    try {
        let uci_core = require("core.uci");
        let cursor = uci_core ? uci_core.cursor() : null;
        if (cursor) {
            cursor.load("dhcp");
            cursor.foreach("dhcp", "host", function(host) {
                let m_list = host.mac;
                if (type(m_list) != "array")
                    m_list = [ m_list ];
                for (let m in m_list) {
                    if (lc(replace(trim(as_string(m)), "-", ":")) == mac) {
                        let ip = host.ip;
                        if (ip && valid_ip(ip) && !seen[ip]) {
                            seen[ip] = true;
                            push(matched, ip);
                        }
                    }
                }
            });
        }
    } catch (e) {}

    return matched;
}

function normalize_to_cidrs(items) {
    if (type(items) != "array")
        items = items != null && items != "" ? [ items ] : [];
    let result = [];
    let seen = {};
    for (let raw in items) {
        let val = trim(as_string(raw));
        if (val == "") continue;
        if (valid_mac(val)) {
            for (let res_ip in resolve_mac_to_ips(val)) {
                let cidr = valid_ipv6(res_ip) ? res_ip + "/128" : res_ip + "/32";
                if (!seen[cidr]) {
                    seen[cidr] = true;
                    push(result, cidr);
                }
            }
            continue;
        }
        if (valid_ip(val)) {
            let cidr = valid_ipv6(val) ? val + "/128" : val + "/32";
            if (!seen[cidr]) {
                seen[cidr] = true;
                push(result, cidr);
            }
        } else if (valid_ip_cidr(val)) {
            if (!seen[val]) {
                seen[val] = true;
                push(result, val);
            }
        }
    }
    return result;
}

const CLOUDFLARE_SHARED_CIDRS = [
    "104.16.0.0/12", "104.24.0.0/14", "172.64.0.0/13", "162.158.0.0/15",
    "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20", "197.234.240.0/22",
    "198.41.128.0/17", "162.159.0.0/16", "173.245.48.0/20", "103.21.244.0/22",
    "103.22.200.0/22", "103.31.4.0/22", "141.101.64.0/18",
    "2606:4700::/32", "2400:cb00::/32", "2405:b500::/32", "2803:f800::/32",
    "2a06:98c0::/29", "2c0f:f248::/32"
];

function is_cloudflare_shared_cidr(value) {
    value = lc(trim(as_string(value)));
    for (let c in CLOUDFLARE_SHARED_CIDRS) {
        if (value == lc(c))
            return true;
    }
    return false;
}

return {
    valid_ipv4,
    valid_ipv4_cidr,
    valid_ipv6,
    valid_ipv6_cidr,
    valid_ip,
    valid_ip_cidr,
    valid_ip_or_cidr,
    valid_mac,
    nft_ip_or_cidr,
    ip_family,
    format_ipv6_tproxy_target,
    ipv6_supported,
    resolve_mac_to_ips,
    normalize_to_cidrs,
    CLOUDFLARE_SHARED_CIDRS,
    is_cloudflare_shared_cidr
};

