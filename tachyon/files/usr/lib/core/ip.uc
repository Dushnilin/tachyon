#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let as_string = common.as_string;

function decimal_text(value, strict) {
    value = as_string(value);
    // ltrim() with a char set is native; match() costs ~50us per call on router CPUs.
    if (value == "" || ltrim(value, "0123456789") != "")
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
    return value != "" && length(value) <= 4 && ltrim(value, "0123456789abcdefABCDEF") == "";
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
    if (value == "" || index(value, ":") < 0 || index(value, "/") >= 0 || index(value, "%") >= 0)
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

function valid_ipv6_zone(value) {
    value = as_string(value);
    let pct = index(value, "%");
    if (pct <= 0 || index(substr(value, pct + 1), "%") >= 0)
        return false;
    let addr = substr(value, 0, pct);
    let zone = substr(value, pct + 1);
    if (zone == "" || length(zone) > 32 || match(zone, /^[A-Za-z0-9_.:-]+$/) == null)
        return false;
    return valid_ipv6(addr);
}

function valid_ip(value) {
    return valid_ipv4(value, false, false) || valid_ipv6(value);
}

function valid_ip_with_zone(value) {
    return valid_ip(value) || valid_ipv6_zone(value);
}

function valid_ip_cidr(value) {
    return valid_ipv4_cidr(value, false) || valid_ipv6_cidr(value);
}

// Quick character-level filter before calling iptoarr() or legacy split/regex
// validators on domain names (e.g. 100k domains in plain lists).
function can_be_ip_or_cidr(value) {
    let text = as_string(value);
    let len = length(text);
    if (len < 2 || len > 49)
        return false;
    if (index(text, ":") >= 0)
        return true;
    let b0 = ord(text, 0);
    if (b0 < 48 || b0 > 57)
        return false;
    return ltrim(text, "0123456789./") == "";
}

// Native parsing avoids repeatedly walking every octet/hextet in large lists.
// Keep the existing validators as a fallback for older ucode and legacy forms
// such as IPv4 with leading zeroes or nft's optional trailing dot.
function native_ip_cidr_family(value, strict_decimal) {
    if (!can_be_ip_or_cidr(value))
        return 0;
    if (type(global.iptoarr) != "function")
        return 0;

    value = as_string(value);
    // Leave embedded NULs to the legacy validators instead of relying on
    // inet_pton() stopping at the end of a C string.
    if (index(value, "\u0000") >= 0)
        return 0;

    let slash = index(value, "/");
    let address = slash < 0 ? value : substr(value, 0, slash);
    let parsed = iptoarr(address);
    if (parsed == null)
        return 0;

    let family = length(parsed) == 4 ? 4 : 6;
    if (slash >= 0) {
        let prefix = substr(value, slash + 1);
        if (!decimal_text(prefix, family == 4 && strict_decimal))
            return 0;
        let bits = int(prefix);
        if (!(bits >= 0 && bits <= (family == 4 ? 32 : 128)))
            return 0;
    }

    return family;
}

function valid_ip_or_cidr(value) {
    if (!can_be_ip_or_cidr(value))
        return false;
    if (native_ip_cidr_family(value, false) != 0)
        return true;
    return valid_ip(value) || valid_ip_cidr(value);
}

function nft_ip_or_cidr(value) {
    if (!can_be_ip_or_cidr(value))
        return false;
    if (native_ip_cidr_family(value, true) != 0)
        return true;
    return valid_ipv4(value, true, true) || valid_ipv4_cidr(value, true) || valid_ipv6(value) || valid_ipv6_cidr(value);
}

function ip_family(value) {
    if (!can_be_ip_or_cidr(value))
        return 0;
    let family = native_ip_cidr_family(value, false);
    if (family != 0)
        return family;
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
    let mock_leases = getenv("TACHYON_MOCK_DHCP_LEASES");
    if (mock_leases != null && mock_leases != "") {
        if (index(mock_leases, "=") >= 0) {
            for (let pair in split(as_string(mock_leases), /[;,\n\t ]+/)) {
                let eq = index(pair, "=");
                if (eq > 0) {
                    let m = lc(replace(trim(substr(pair, 0, eq)), "-", ":"));
                    let ip = trim(substr(pair, eq + 1));
                    if (m == mac && valid_ip(ip) && !seen[ip]) {
                        seen[ip] = true;
                        push(matched, ip);
                    }
                }
            }
        } else {
            lease_files = [ mock_leases, ...lease_files ];
        }
    }
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

    // IPv6 SLAAC / NDP neighbor cache lookup (global & ULA, skip link-local fe80::/10 and FAILED).
    let neigh_text = "";
    let mock_neigh = getenv("TACHYON_MOCK_IP6_NEIGH");
    if (mock_neigh != null && mock_neigh != "") {
        if (index(mock_neigh, "/") == 0)
            neigh_text = as_string(fs.readfile(mock_neigh) || "");
        else
            neigh_text = as_string(mock_neigh);
    } else if (getenv("TACHYON_NO_LIVE_NET_PROBE") != "1") {
        neigh_text = common.command_output_from_args([ "ip", "-6", "neigh", "show" ]);
    }
    for (let line in split(neigh_text, "\n")) {
        line = trim(line);
        if (line == "" || index(line, "FAILED") >= 0)
            continue;
        let fields = split(line, /[ \t]+/);
        if (length(fields) < 4)
            continue;
        let ip = fields[0];
        if (!valid_ipv6(ip) || match(lc(ip), /^fe[89ab][0-9a-f]?:/) != null)
            continue;
        let ll_idx = index(fields, "lladdr");
        if (ll_idx < 0 || ll_idx + 1 >= length(fields))
            continue;
        let m = lc(replace(trim(fields[ll_idx + 1]), "-", ":"));
        if (m == mac && !seen[ip]) {
            seen[ip] = true;
            push(matched, ip);
        }
    }

    // DHCPv6 leases via ubus (or test mock), when lease entry exposes mac.
    let leases_raw = "";
    let mock_v6_leases = getenv("TACHYON_MOCK_UBUS_IPV6LEASES");
    if (mock_v6_leases != null && mock_v6_leases != "") {
        leases_raw = substr(mock_v6_leases, 0, 1) == "{" ? mock_v6_leases : as_string(fs.readfile(mock_v6_leases) || "");
    } else if (getenv("TACHYON_NO_LIVE_NET_PROBE") != "1") {
        leases_raw = common.command_output(common.bounded_command(common.command_from_args([ "ubus", "call", "dhcp", "ipv6leases" ]), 2) + " 2>/dev/null");
    }
    if (trim(leases_raw) != "") {
        let parsed_leases = null;
        try { parsed_leases = json(leases_raw); } catch (e) { parsed_leases = null; }
        let devs = type(parsed_leases) == "object" ? common.object_or_empty(parsed_leases.device) : {};
        for (let dev_name in keys(devs)) {
            let dev_obj = common.object_or_empty(devs[dev_name]);
            for (let lease in common.array_or_empty(dev_obj.leases)) {
                if (type(lease) != "object")
                    continue;
                let lm = lc(replace(trim(as_string(lease.mac || "")), "-", ":"));
                if (lm != mac)
                    continue;
                for (let a in common.array_or_empty(lease["ipv6-addr"])) {
                    let ip = type(a) == "object" ? trim(as_string(a.address || "")) : trim(as_string(a));
                    if (ip != "" && valid_ipv6(ip) && match(lc(ip), /^fe[89ab][0-9a-f]?:/) == null && !seen[ip]) {
                        seen[ip] = true;
                        push(matched, ip);
                    }
                }
            }
        }
    }

    return matched;
}

function parse_ipv4_bytes_pure(addr) {
    let parts = split(addr, ".");
    if (length(parts) != 4)
        return null;
    let out = [];
    for (let p in parts) {
        if (!decimal_text(p, false))
            return null;
        let v = int(p);
        if (v < 0 || v > 255)
            return null;
        push(out, v);
    }
    return out;
}

function expand_ipv6_hextets(addr) {
    if (!valid_ipv6(addr))
        return null;
    let marker = index(addr, "::");
    let left_parts = [];
    let right_parts = [];
    if (marker >= 0) {
        let l = substr(addr, 0, marker);
        let r = substr(addr, marker + 2);
        if (l != "")
            left_parts = split(l, ":");
        if (r != "")
            right_parts = split(r, ":");
    } else {
        left_parts = split(addr, ":");
    }

    let normalize_side = function(parts) {
        let words = [];
        for (let i = 0; i < length(parts); i++) {
            let p = parts[i];
            if (index(p, ".") >= 0) {
                let v4 = parse_ipv4_bytes_pure(p);
                if (!v4)
                    return null;
                push(words, (v4[0] * 256) + v4[1]);
                push(words, (v4[2] * 256) + v4[3]);
            } else {
                push(words, hex(p));
            }
        }
        return words;
    };

    let left_words = normalize_side(left_parts);
    let right_words = normalize_side(right_parts);
    if (!left_words || !right_words)
        return null;

    let zeros = 8 - length(left_words) - length(right_words);
    if (zeros < 0)
        return null;
    let all = [];
    for (let w in left_words) push(all, w);
    for (let i = 0; i < zeros; i++) push(all, 0);
    for (let w in right_words) push(all, w);
    return length(all) == 8 ? all : null;
}

function parse_ip_bytes(addr) {
    addr = trim(as_string(addr));
    if (addr == "")
        return null;
    if (type(global.iptoarr) == "function" && index(addr, "\u0000") < 0) {
        let arr = iptoarr(addr);
        if (type(arr) == "array" && (length(arr) == 4 || length(arr) == 16))
            return arr;
    }
    if (valid_ipv4(addr, false, false))
        return parse_ipv4_bytes_pure(addr);
    let words = expand_ipv6_hextets(addr);
    if (!words)
        return null;
    let out = [];
    for (let w in words) {
        push(out, (w >> 8) & 255);
        push(out, w & 255);
    }
    return out;
}

function format_ip_bytes(bytes) {
    if (type(bytes) != "array")
        return "";
    if (type(global.arrtoip) == "function")
        return as_string(arrtoip(bytes));
    if (length(bytes) == 4)
        return sprintf("%d.%d.%d.%d", bytes[0], bytes[1], bytes[2], bytes[3]);
    if (length(bytes) != 16)
        return "";

    let words = [];
    for (let i = 0; i < 16; i += 2)
        push(words, ((bytes[i] & 255) << 8) | (bytes[i + 1] & 255));

    let best_start = -1;
    let best_len = 0;
    let cur_start = -1;
    let cur_len = 0;
    for (let i = 0; i < 8; i++) {
        if (words[i] == 0) {
            if (cur_start < 0) {
                cur_start = i;
                cur_len = 1;
            } else {
                cur_len++;
            }
            if (cur_len > best_len) {
                best_start = cur_start;
                best_len = cur_len;
            }
        } else {
            cur_start = -1;
            cur_len = 0;
        }
    }
    if (best_len < 2) {
        best_start = -1;
        best_len = 0;
    }

    let parts = [];
    for (let i = 0; i < 8; i++) {
        if (i == best_start) {
            if (length(parts) == 0)
                push(parts, "");
            push(parts, "");
            i += best_len - 1;
            continue;
        }
        push(parts, sprintf("%x", words[i]));
    }
    let joined = join(":", parts);
    if (best_start >= 0 && best_start + best_len == 8 && substr(joined, length(joined) - 2) != "::")
        joined += ":";
    return joined;
}

function parse_cidr_parts(value) {
    value = trim(as_string(value));
    if (value == "")
        return null;
    let slash = index(value, "/");
    let addr = slash < 0 ? value : substr(value, 0, slash);
    let bytes = parse_ip_bytes(addr);
    if (!bytes)
        return null;
    let max_bits = length(bytes) * 8;
    let prefix = max_bits;
    if (slash >= 0) {
        let ptxt = substr(value, slash + 1);
        if (!decimal_text(ptxt, false))
            return null;
        prefix = int(ptxt);
        if (prefix < 0 || prefix > max_bits)
            return null;
    }
    return { bytes: bytes, prefix: prefix, family: length(bytes) == 4 ? 4 : 6 };
}

function mask_cidr(value) {
    let parsed = parse_cidr_parts(value);
    if (!parsed)
        return "";
    let out = [];
    let rem = parsed.prefix;
    for (let b in parsed.bytes) {
        if (rem >= 8) {
            push(out, b & 255);
            rem -= 8;
        } else if (rem > 0) {
            let mask = (255 << (8 - rem)) & 255;
            push(out, b & mask);
            rem = 0;
        } else {
            push(out, 0);
        }
    }
    return format_ip_bytes(out) + "/" + as_string(parsed.prefix);
}

function cidrs_overlap(a, b) {
    let pa = parse_cidr_parts(a);
    let pb = parse_cidr_parts(b);
    if (!pa || !pb || pa.family != pb.family)
        return false;
    let common_bits = pa.prefix < pb.prefix ? pa.prefix : pb.prefix;
    for (let i = 0; i < length(pa.bytes) && common_bits > 0; i++) {
        let bits = common_bits >= 8 ? 8 : common_bits;
        let mask = bits == 8 ? 255 : ((255 << (8 - bits)) & 255);
        if ((pa.bytes[i] & mask) != (pb.bytes[i] & mask))
            return false;
        common_bits -= bits;
    }
    return true;
}

function lan_ipv6_prefixes(interfaces) {
    let out = [];
    let seen = {};
    let add_cidr = function(raw) {
        let masked = mask_cidr(raw);
        if (masked == "" || index(masked, ":") < 0)
            return;
        if (match(lc(masked), /^fe[89ab][0-9a-f]?:/) != null || masked == "::1/128")
            return;
        if (!seen[masked]) {
            seen[masked] = true;
            push(out, masked);
        }
    };

    let mock = trim(as_string(getenv("TACHYON_MOCK_LAN_PREFIX6") || ""));
    if (mock != "") {
        for (let item in split(mock, /[ \t\r\n,;]+/))
            add_cidr(item);
        return out;
    }

    if (getenv("TACHYON_NO_LIVE_NET_PROBE") == "1")
        return out;

    let ifaces = type(interfaces) == "array" ? interfaces : [];
    if (length(ifaces) == 0)
        ifaces = [ "br-lan" ];

    for (let dev in ifaces) {
        dev = trim(as_string(dev));
        if (dev == "")
            continue;
        let text = common.command_output_from_args([ "ip", "-6", "-o", "addr", "show", "dev", dev, "scope", "global" ]);
        for (let line in split(as_string(text), "\n")) {
            line = trim(line);
            if (line == "")
                continue;
            let m = match(line, /inet6[ \t]+([^ \t]+)/);
            if (m)
                add_cidr(m[1]);
        }
    }
    return out;
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

function core_needs_ipv4_mapped_cidrs() {
    let ver = trim(as_string(getenv("TACHYON_CORE_VERSION_OVERRIDE") || ""));
    if (ver == "") {
        let raw = fs.readfile("/etc/tachyon/tachyon-core-version");
        ver = trim(as_string(raw || ""));
    }
    if (ver == "")
        return true;
    let m = match(ver, /^v?([0-9]+)\.([0-9]+)\.([0-9]+)/);
    if (m == null)
        return true;
    let major = int(m[1]);
    let minor = int(m[2]);
    let patch = int(m[3]);
    if (major == 0 && (minor > 3 || (minor == 3 && patch >= 1)))
        return false;
    return true;
}

function expand_ipv4_mapped_cidrs(cidrs, include_ipv6_mapped) {
    let arr = type(cidrs) == "array" ? cidrs : (cidrs != null && as_string(cidrs) != "" ? [ cidrs ] : []);
    let map_v6 = include_ipv6_mapped != null ? !!include_ipv6_mapped : (ipv6_supported() && core_needs_ipv4_mapped_cidrs());
    let result = [];
    let seen = {};
    let push_unique = function(val) {
        val = trim(as_string(val));
        if (val != "" && !seen[val]) {
            seen[val] = true;
            push(result, val);
        }
    };

    for (let item in arr) {
        let val = trim(as_string(item));
        if (val == "")
            continue;
        push_unique(val);
        if (!map_v6)
            continue;
        if (valid_ipv4_cidr(val, false)) {
            let slash = index(val, "/");
            let addr = substr(val, 0, slash);
            let prefix = int(substr(val, slash + 1));
            push_unique("::ffff:" + addr + "/" + as_string(96 + prefix));
        } else if (valid_ipv4(val, false, false)) {
            push_unique("::ffff:" + val + "/128");
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

// Discord does not only listen on 443. Voice is UDP, but media also runs over TCP
// on the alternate Cloudflare edge ports 2053, 2083, 2087, 2096 and 8443, and the
// fuzzer's nft scope already listed them while this section did not route them.
// Kept apart from the voice ports because both consumers are protocol-specific:
// apply.uc feeds DISCORD_VOICE_PORTS_NFT into the UDP port sets, and the tachyon-core
// voice rule is network=udp. The voice UDP range stays 50000-65535, which is what
// Discord documents and where allocations above 50100 do occur.
const DISCORD_VOICE_PORTS_NFT = "443, 5000-5020, 3478, 19294-19344, 50000-65535";
const DISCORD_VOICE_PORT_RANGES = [ "443:443", "5000:5020", "3478:3478", "19294:19344", "50000:65535" ];
const DISCORD_MEDIA_PORTS_NFT = "443, 1080, 2053, 2083, 2087, 2096, 8443";
const DISCORD_MEDIA_PORT_RANGES = [ "443:443", "1080:1080", "2053:2053", "2083:2083", "2087:2087", "2096:2096", "8443:8443" ];
const DEFAULT_DISCORD_VOICE_SUBNETS = [ "104.16.0.0/12", "162.158.0.0/15", "172.64.0.0/13", "2606:4700::/32" ];
// Discord's edge is spread across 162.159.128.0/20: discord.com answers on
// .128, .135, .136, .137 and .138. The old /21 stopped at .135.255, so roughly
// half of the addresses a resolver hands out fell outside the Discord section
// and bypassed it without explicit subnet coverage. The whole /20 is CLOUDFLARENET (RIPE), the
// operator Discord already runs on, so widening sweeps in nothing unrelated.
const DISCORD_DEDICATED_SUBNETS = [ "162.159.128.0/20" ];

// Telegram Datacenter & Edge Subnets (AS44907, AS59930, AS62014, AS62041).
// Desktop and mobile Telegram apps connect to hardcoded MTProto Datacenter IPs
// directly without issuing DNS queries; these CIDRs ensure traffic is redirected
// and routed to proxy/desync outbounds even when offline or before ruleset downloads.
const DEFAULT_TELEGRAM_SUBNETS = [
    "5.28.192.0/18",
    "91.105.192.0/23",
    "91.108.4.0/22",
    "91.108.8.0/21",
    "91.108.16.0/21",
    "91.108.56.0/22",
    "95.161.64.0/20",
    "149.154.160.0/20",
    "185.76.151.0/24",
    "194.221.0.0/16"
];

const DEFAULT_TELEGRAM_SUBNETS6 = [
    "2001:67c:4e8::/48",
    "2001:b28:f23c::/47",
    "2001:b28:f23f::/48",
    "2a0a:f280::/32"
];

return {
    valid_ipv4,
    valid_ipv4_cidr,
    valid_ipv6,
    valid_ipv6_cidr,
    valid_ipv6_zone,
    valid_ip,
    valid_ip_cidr,
    valid_ip_with_zone,
    valid_ip_or_cidr,
    valid_mac,
    nft_ip_or_cidr,
    ip_family,
    format_ipv6_tproxy_target,
    ipv6_supported,
    resolve_mac_to_ips,
    normalize_to_cidrs,
    expand_ipv4_mapped_cidrs,
    parse_ip_bytes,
    mask_cidr,
    cidrs_overlap,
    lan_ipv6_prefixes,
    CLOUDFLARE_SHARED_CIDRS,
    is_cloudflare_shared_cidr,
    DISCORD_VOICE_PORTS_NFT,
    DISCORD_VOICE_PORT_RANGES,
    DISCORD_MEDIA_PORTS_NFT,
    DISCORD_MEDIA_PORT_RANGES,
    DEFAULT_DISCORD_VOICE_SUBNETS,
    DISCORD_DEDICATED_SUBNETS,
    DEFAULT_TELEGRAM_SUBNETS,
    DEFAULT_TELEGRAM_SUBNETS6
};

