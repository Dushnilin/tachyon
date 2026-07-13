#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"

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

// format_ipv6_tproxy_target
assert(ip.format_ipv6_tproxy_target("2001:db8::1", 1234) == "[2001:db8::1]:1234", "format IPv6 target");
'

printf 'core/ip checks passed\n'
