#!/usr/bin/env bash
# A Hysteria2 finalmask that only carries QUIC tuning is not obfuscation.
#
# Some panels emit fm={"quicParams":{...}} with no "udp" list and no "type".
# The parser used to take the bare object as a UDP item and default it to
# salamander, producing obfs without a password; the core then rejected the
# whole section with "missing obfs password". Untyped items inside an explicit
# "udp" list and a typed bare object must still give salamander.
#
# The test fails on the code before the fix: the quicParams-only link gets obfs.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

out="$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" - <<'UCODE'
let parser = require("subscription.parser");
let base = "hysteria2://secret@hy.example.com:443/?sni=hy.example.com&fm=";

// 1. QUIC tuning only: no obfuscation.
let quic = parser.parse_share_link(base + "%7B%22quicParams%22%3A%7B%22debug%22%3Afalse%2C%22congestion%22%3A%22bbr%22%7D%7D#HY");
if (quic == null || quic.type != "hysteria2") {
    warn("quicParams-only link did not parse\n");
    exit(1);
}
if (quic.obfs != null) {
    warn("quicParams-only fm enabled obfuscation\n");
    exit(1);
}

// 2. An untyped item inside an explicit udp list still defaults to salamander.
let listed = parser.parse_share_link(base + "%7B%22udp%22%3A%5B%7B%22settings%22%3A%7B%22password%22%3A%22pw%22%7D%7D%5D%7D#HY");
if (listed == null || listed.obfs == null || listed.obfs.type != "salamander" || listed.obfs.password != "pw") {
    warn("untyped udp item lost its salamander default\n");
    exit(1);
}

// 3. A typed bare object keeps salamander with its password.
let typed = parser.parse_share_link(base + "%7B%22type%22%3A%22salamander%22%2C%22password%22%3A%22pw2%22%7D#HY");
if (typed == null || typed.obfs == null || typed.obfs.type != "salamander" || typed.obfs.password != "pw2") {
    warn("typed bare finalmask lost salamander\n");
    exit(1);
}

print("ok");
UCODE
)" || fail "Hysteria2 finalmask parsing"

[ "$out" = "ok" ] || fail "unexpected output: $out"
printf 'Hysteria2 quicParams-only finalmask does not enable obfs passed\n'
