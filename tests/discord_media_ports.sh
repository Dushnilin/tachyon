#!/usr/bin/env bash
# Discord media runs on TCP 2053, 2083, 2087, 2096 and 8443 as well as 443.
#
# The voice half was handled and the media half was not: apply.uc fed the voice
# ports into the UDP port sets, and the sing-box rule was network=udp. So a section
# captured voice and let media through on whatever port it happened to use. The
# fuzzer's nft scope already listed the five ports, which made the gap visible: it
# was measuring ports the section did not route.
#
# Protocol separation is the point. Merging the TCP ports into the voice list would
# put 2053..8443 into a UDP port set, and sing-box would ignore them there.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -z "$TACHYON_LIB" ]; then
  if [ -d "$ROOT_DIR/tachyon/files/usr/lib/diagnostics" ]; then
    TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
  else
    TACHYON_LIB="/usr/lib/tachyon"
  fi
fi

ucode() { command ucode -L "$TACHYON_LIB" "$@"; }

pass_count=0
ok() { pass_count=$((pass_count + 1)); }

IP_UC="$TACHYON_LIB/core/ip.uc"
GEN="$TACHYON_LIB/singbox/generator_routes.uc"
APPLY="$TACHYON_LIB/nft/apply.uc"
for f in "$IP_UC" "$GEN" "$APPLY"; do
  [ -f "$f" ] || fail "missing $f"
done

cat >"$WORK_DIR/media_ports.uc" <<'UCODE'
let ip = require("core.ip");

let MEDIA_TCP = [ "2053", "2083", "2087", "2096", "8443" ];
let errors = [];
let note = function(m) { push(errors, m); };

// The media ports exist as their own constant...
if (type(ip.DISCORD_MEDIA_PORT_RANGES) != "array")
    note("core.ip must expose DISCORD_MEDIA_PORT_RANGES");
else if (length(ip.DISCORD_MEDIA_PORT_RANGES) != length(MEDIA_TCP))
    note("DISCORD_MEDIA_PORT_RANGES has " + length(ip.DISCORD_MEDIA_PORT_RANGES) + " entries, expected " + length(MEDIA_TCP));

for (let port in MEDIA_TCP) {
    let range = port + ":" + port;
    if (type(ip.DISCORD_MEDIA_PORT_RANGES) == "array" &&
        index(ip.DISCORD_MEDIA_PORT_RANGES, range) < 0)
        note("DISCORD_MEDIA_PORT_RANGES is missing " + range);
    if (index(ip.DISCORD_MEDIA_PORTS_NFT || "", port) < 0)
        note("DISCORD_MEDIA_PORTS_NFT is missing " + port);
}

// ...and did not leak into the UDP voice sets, whose only consumer is network=udp.
for (let port in MEDIA_TCP) {
    for (let range in (type(ip.DISCORD_VOICE_PORT_RANGES) == "array" ? ip.DISCORD_VOICE_PORT_RANGES : [])) {
        if (index(range, port + ":") == 0)
            note("TCP port " + port + " leaked into the UDP voice ranges");
    }
    if (index(ip.DISCORD_VOICE_PORTS_NFT || "", port) >= 0)
        note("TCP port " + port + " leaked into the UDP voice port list");
}

// The voice UDP range is Discord's documented one. Narrowing it to 50000-50100
// because a community config uses that would break voice for anyone whose
// allocation lands above it.
if (index(ip.DISCORD_VOICE_PORT_RANGES || [], "50000:65535") < 0)
    note("the voice UDP range must stay 50000:65535");

if (length(errors) > 0) {
    for (let e in errors) printf("%s\n", e);
    exit(1);
}
printf("discord media ports ok\n");
UCODE

if out="$(ucode "$WORK_DIR/media_ports.uc" 2>&1)"; then
  printf 'discord media ports: %s\n' "$out"
else
  fail "Discord media ports are wrong:
$out"
fi

# Both consumers must actually use them, or the constants are decoration.
strip_comments() { grep -v '^[[:space:]]*//' "$1"; }
strip_comments "$GEN" >"$WORK_DIR/gen_nc.uc"
strip_comments "$APPLY" >"$WORK_DIR/apply_nc.uc"

grep -q 'DISCORD_MEDIA_PORT_RANGES' "$WORK_DIR/gen_nc.uc" ||
  fail "generator_routes.uc must build a TCP rule from DISCORD_MEDIA_PORT_RANGES"
ok

grep -q 'media_rule.network = "tcp"' "$WORK_DIR/gen_nc.uc" ||
  fail "the Discord media rule must be TCP; the voice rule above it is UDP"
ok

grep -q 'DISCORD_MEDIA_PORTS_NFT' "$WORK_DIR/apply_nc.uc" ||
  fail "apply.uc must populate the ip_port sets with the Discord media ports"
ok

# The TCP branch must use the ip_port sets and the UDP branch the udp_port sets.
if grep -q 'ip-port-from-ip", media_ports' "$WORK_DIR/apply_nc.uc" &&
   grep -q 'ip-port-from-ip", voice_ports' "$WORK_DIR/apply_nc.uc"; then
  ok
else
  fail "apply.uc must feed media_ports to the ip_port sets and voice_ports to the udp_port sets"
fi

printf 'PASS: discord_media_ports\n'