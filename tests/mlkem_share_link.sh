#!/usr/bin/env bash
# Issue #245: the hybrid key share flag has to survive a share link.
#
# Three spellings are in the wild - the sing-box snake_case one, the camelCase
# one some panels emit and the kebab-case one a share link carries. All three
# have to be understood, the priority order has to be kept, an explicit false
# must never turn into true, and the flag must survive a round trip through
# the share link serializer.
#
# The test fails on the code before the fix: the kebab-case spelling is
# dropped, and the serializer writes no flag at all.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

out="$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" - <<'UCODE'
let parser = require("subscription.parser");
let share_link = require("subscription.share_link");

function parse_link(link) {
    let outbound = parser.parse_share_link(link);
    if (outbound == null || type(outbound.tls) != "object")
        return null;
    return outbound.tls;
}

let base = "vless://11111111-1111-1111-1111-111111111111@example.com:443?type=tcp&security=reality&pbk=KEY&sid=ab&fp=chrome";

// 1. Every spelling has to be understood.
let snake = parse_link(base + "&support_x25519mlkem768=true");
let camel = parse_link(base + "&supportX25519MLKEM768=true");
let kebab = parse_link(base + "&support-x25519mlkem768=true");
if (snake == null || snake.reality == null || snake.reality.support_x25519mlkem768 !== true) {
    warn("snake_case spelling not carried\n");
    exit(1);
}
if (camel == null || camel.reality == null || camel.reality.support_x25519mlkem768 !== true) {
    warn("camelCase spelling not carried\n");
    exit(1);
}
if (kebab == null || kebab.reality == null || kebab.reality.support_x25519mlkem768 !== true) {
    warn("kebab-case spelling not carried\n");
    exit(1);
}

// 2. An explicit false stays false.
let explicit_false = parse_link(base + "&support_x25519mlkem768=false");
if (explicit_false == null || explicit_false.reality == null ||
    explicit_false.reality.support_x25519mlkem768 !== false) {
    warn("explicit false was not kept\n");
    exit(1);
}

// 3. An absent flag stays absent - it must not be turned into true.
let absent = parse_link(base);
if (absent == null || absent.reality == null || absent.reality.support_x25519mlkem768 != null) {
    warn("an absent flag must stay absent\n");
    exit(1);
}

// 4. The priority order is kept: the first spelling that is present wins.
let both = parse_link(base + "&support_x25519mlkem768=false&support-x25519mlkem768=true");
if (both == null || both.reality == null || both.reality.support_x25519mlkem768 !== false) {
    warn("the snake_case spelling has to win over the kebab-case one\n");
    exit(1);
}

// 5. The flag survives a round trip through the share link serializer.
let link = share_link.serialize_outbound_link({
    type: "vless",
    tag: "node",
    server: "example.com",
    server_port: 443,
    uuid: "11111111-1111-1111-1111-111111111111",
    tls: {
        enabled: true,
        server_name: "example.com",
        reality: {
            enabled: true,
            public_key: "KEY",
            short_id: "ab",
            support_x25519mlkem768: true
        }
    }
});
if (index(link, "support-x25519mlkem768=1") < 0) {
    warn("the serializer dropped the ML-KEM flag: " + link + "\n");
    exit(1);
}

// 6. And the round trip has to parse back to the same value.
let back = parse_link(link);
if (back == null || back.reality == null || back.reality.support_x25519mlkem768 !== true) {
    warn("the round trip lost the ML-KEM flag\n");
    exit(1);
}

print("ok");
UCODE
)"

[ "$out" = "ok" ] || fail "ML-KEM flag handling is broken: $out"

printf 'ML-KEM share link flag handling passed\n'
