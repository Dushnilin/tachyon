#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

ucode -L "$TACHYON_LIB" -e '
let ip = require("core.ip");

function assert(val, msg) {
    if (!val) {
        warn("Assertion failed: " + msg + "\n");
        exit(1);
    }
}

// valid_ipv4
assert(ip.valid_ipv4("1.1.1.1"), "1.1.1.1 should be valid");
assert(ip.valid_ipv4("255.255.255.255"), "255.255.255.255 should be valid");
assert(!ip.valid_ipv4("256.1.1.1"), "256.1.1.1 should be invalid");
assert(!ip.valid_ipv4("1.1.1.1.1"), "1.1.1.1.1 should be invalid");
assert(!ip.valid_ipv4("abc"), "abc should be invalid");

// valid_ipv4_cidr
assert(ip.valid_ipv4_cidr("1.1.1.1/32"), "1.1.1.1/32 should be valid");
assert(ip.valid_ipv4_cidr("192.168.1.0/24"), "192.168.1.0/24 should be valid");
assert(!ip.valid_ipv4_cidr("1.1.1.1/33"), "1.1.1.1/33 should be invalid");
assert(!ip.valid_ipv4_cidr("256.1.1.1/24"), "256.1.1.1/24 should be invalid");

// valid_ipv6
assert(ip.valid_ipv6("2001:db8::1"), "2001:db8::1 should be valid");
assert(ip.valid_ipv6("::1"), "::1 should be valid");
assert(!ip.valid_ipv6("2001:db8:::1"), "2001:db8:::1 should be invalid");

// valid_ipv6_cidr
assert(ip.valid_ipv6_cidr("2001:db8::1/64"), "2001:db8::1/64 should be valid");
assert(ip.valid_ipv6_cidr("::1/128"), "::1/128 should be valid");
assert(!ip.valid_ipv6_cidr("2001:db8::1/129"), "2001:db8::1/129 should be invalid");

// ip_family
assert(ip.ip_family("1.1.1.1") == 4, "family of 1.1.1.1 is 4");
assert(ip.ip_family("2001:db8::1") == 6, "family of 2001:db8::1 is 6");
assert(ip.ip_family("abc") == 0, "family of abc is 0");

// The native fast path must preserve strict nft syntax, legacy IPv4 forms,
// CIDR bounds and rejection of malformed IPv6.
let cases = [
    ["0.0.0.0", true, true, 4],
    ["255.255.255.255/32", true, true, 4],
    ["192.0.2.0/0", true, true, 4],
    ["192.0.2.0/00", true, false, 4],
    ["001.002.003.004", true, false, 4],
    ["001.002.003.004/24", true, false, 4],
    ["192.0.2.1.", false, true, 0],
    ["192.0.2.1./24", false, false, 0],
    ["192.0.2.0/33", false, false, 0],
    ["192.0.2.0/-1", false, false, 0],
    ["192.0.2.0/24/1", false, false, 0],
    ["192.0.2.0/", false, false, 0],
    ["192.0.2.0/ 24", false, false, 0],
    ["192.0.2.0/24\n", false, false, 0],
    ["256.0.0.1", false, false, 0],
    ["1.2.3", false, false, 0],
    ["2130706433", false, false, 0],
    ["::", true, true, 6],
    ["2001:db8::1/128", true, true, 6],
    ["2001:db8::/000", true, true, 6],
    ["2001:db8::/129", false, false, 0],
    ["2001:db8:::1", false, false, 0],
    ["::ffff:192.0.2.1", true, true, 6],
    ["::ffff:001.002.003.004/96", true, true, 6],
    ["fe80::1%eth0", false, false, 0],
    ["[::1]", false, false, 0],
    ["", false, false, 0]
];
let native_parser = global.iptoarr;
for (let use_native in [true, false]) {
    global.iptoarr = use_native ? native_parser : null;
    for (let c in cases) {
        let label = sprintf("%J (native=%J)", c[0], use_native);
        assert(ip.valid_ip_or_cidr(c[0]) == c[1], "valid_ip_or_cidr " + label);
        assert(ip.nft_ip_or_cidr(c[0]) == c[2], "nft_ip_or_cidr " + label);
        assert(ip.ip_family(c[0]) == c[3], "ip_family " + label);
    }
}
global.iptoarr = native_parser;

// format_ipv6_tproxy_target
assert(ip.format_ipv6_tproxy_target("2001:db8::1", 1234) == "[2001:db8::1]:1234", "format IPv6 target");

// ipv6_supported function exists and returns boolean
assert(type(ip.ipv6_supported()) == "bool", "ipv6_supported returns bool");
'

# Test override environment variable
[ "$(TACHYON_ENABLE_IPV6=0 ucode -L "$TACHYON_LIB" -e 'let ip = require("core.ip"); print(ip.ipv6_supported() ? "true" : "false");')" = "false" ] || { echo "ipv6 override 0 failed" >&2; exit 1; }
[ "$(TACHYON_ENABLE_IPV6=1 ucode -L "$TACHYON_LIB" -e 'let ip = require("core.ip"); print(ip.ipv6_supported() ? "true" : "false");')" = "true" ] || { echo "ipv6 override 1 failed" >&2; exit 1; }

printf 'core/ip checks passed\n'
