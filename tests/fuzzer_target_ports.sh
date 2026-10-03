#!/usr/bin/env bash
# A target's ports are part of the target.
#
# The strategy lists are TCP/443 TLS desync, so a Discord fuzz run over them could
# not say anything about voice: Discord voice is UDP STUN/RTP on 3478, 5000-5020,
# 19294-19344 and 50000-50100, and its media uses TCP 2053, 2083, 2087, 2096 and
# 8443. The runtime section routes exactly those ports (core/ip.uc
# DISCORD_VOICE_PORT_RANGES), so the fuzzer measuring TCP/443 only was measuring
# the part of Discord least likely to be the problem.
#
# The two engines also have to be written in their own grammar: nfqws2 spells the
# SNI-matched fake as hostfakesplit:host=<h>, nfqws as
# --dpi-desync-hostfakesplit-mod=host=<h>.
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

STRATEGIES="$TACHYON_LIB/diagnostics/fuzzer/strategies.uc"
[ -f "$STRATEGIES" ] || fail "missing $STRATEGIES"

cat >"$WORK_DIR/ports.uc" <<'UCODE'
let s = require("diagnostics.fuzzer.strategies");

let errors = [];
let note = function(m) { push(errors, m); };

let VOICE_UDP = [ "3478", "19294-19344", "50000-65535" ];
let MEDIA_TCP = [ "2053", "2083", "2087", "2096", "8443" ];

let all = function(cond) {
    for (let s2 in cond) if (!s2) return false;
    return true;
};

let z2 = s.target_port_strategies("zapret2", "discord_suite");
let v1 = s.target_port_strategies("zapret", "discord_suite");

if (length(z2) < 3) note("zapret2 produced " + length(z2) + " port-scoped strategies, expected at least 3");
if (length(v1) < 3) note("zapret produced " + length(v1) + " port-scoped strategies, expected at least 3");

// byedpi has no equivalent of --filter-tcp: inventing one would be a lie.
let bd = s.target_port_strategies("byedpi", "discord_suite");
if (length(bd) != 0) note("byedpi must not get port-scoped strategies, got " + length(bd));

// A target with no port profile gets nothing.
if (length(s.target_port_strategies("zapret2", "youtube_suite")) != 0)
    note("youtube_suite must not get Discord's ports");

let joined = function(list) {
    let out = "";
    for (let item in list) out += " " + item.args;
    return out;
};
let z2_text = joined(z2);
let v1_text = joined(v1);

for (let port in VOICE_UDP) {
    if (index(z2_text, port) < 0) note("zapret2 port strategies never mention voice UDP port " + port);
    if (index(v1_text, port) < 0) note("zapret port strategies never mention voice UDP port " + port);
}
for (let port in MEDIA_TCP) {
    if (index(z2_text, port) < 0) note("zapret2 port strategies never mention media TCP port " + port);
    if (index(v1_text, port) < 0) note("zapret port strategies never mention media TCP port " + port);
}

// Each engine in its own grammar, checked the same way as fuzzer_engine_grammar.
for (let item in z2) {
    if (index(item.args, "--lua-desync=") < 0)
        note(item.id + ": a zapret2 strategy without --lua-desync: " + item.args);
    if (index(item.args, "--dpi-desync") >= 0)
        note(item.id + ": v1 flag in a zapret2 strategy: " + item.args);
}
for (let item in v1) {
    if (index(item.args, "--dpi-desync=") < 0)
        note(item.id + ": a zapret strategy without --dpi-desync: " + item.args);
    if (index(item.args, "--lua-desync=") >= 0)
        note(item.id + ": zapret2 flag in a v1 strategy: " + item.args);
}

// The SNI-matched fake exists on both sides, in the spelling of each.
if (index(z2_text, "hostfakesplit:host=") < 0)
    note("zapret2 is missing the hostfakesplit host= variant");
if (index(v1_text, "--dpi-desync-hostfakesplit-mod=host=") < 0)
    note("zapret is missing --dpi-desync-hostfakesplit-mod=host=");
if (index(v1_text, "--dpi-desync-badseq-increment=0") < 0)
    note("zapret is missing --dpi-desync-badseq-increment=0");

// They must reach an actual run, not just exist.
let listed = s.get_strategies_for_engine("zapret2", "presets", "discord_suite");
let scoped = 0;
for (let st in listed) if (st.target_ports) scoped++;
if (scoped < 3) note("a discord_suite run lists " + scoped + " port-scoped strategies, expected at least 3");

if (length(errors) > 0) {
    for (let e in errors) printf("%s\n", e);
    exit(1);
}
printf("target ports ok: zapret2=%d zapret=%d byedpi=0\n", length(z2), length(v1));
UCODE

if out="$(ucode "$WORK_DIR/ports.uc" 2>&1)"; then
  printf 'fuzzer target ports: %s\n' "$out"
else
  fail "target port strategies are wrong:
$out"
fi

printf 'PASS: fuzzer_target_ports\n'