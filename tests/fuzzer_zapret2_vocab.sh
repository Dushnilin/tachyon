#!/usr/bin/env bash
# Every zapret2 strategy is checked against the desync method table and the
# fooling vocabulary of the Lua library that actually ships with zapret2.
#
# This matters more than a usual schema check, because zapret2 accepts nonsense
# without a murmur. Verified on 192.168.1.205 against nfqws2 v1.0.5.2:
#
#   --lua-desync=multisplit:pos=1:fooling=totally_bogus
#     profile 1 (noname) lua multisplit(fooling="totally_bogus",pos="1" ...)
#     exit code 0, no warning
#
# The profile is accepted, the daemon starts, and apply_fooling() then reads only
# the keys it knows (ip_ttl, tcp_seq, tcp_ack, tcp_ts, tcp_md5, badsum, ...). An
# unknown fooling is a silent no-op, so a strategy can look like it works while the
# one protection it names was never applied. The v1 names badseq, md5sig, ts and
# badack do not exist in nfqws2 at all: 20 strategies in strategies.uc and 6
# presets were carrying them.
#
# The two lists below were extracted from the router's own
# /opt/zapret2/lua/zapret-antidpi.lua and zapret-lib.lua, not from documentation.
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
PRESETS="$ROOT_DIR/tachyon/files/usr/share/tachyon/dpi-presets.json"
for f in "$STRATEGIES" "$PRESETS"; do
  [ -f "$f" ] || fail "missing $f"
done

cat >"$WORK_DIR/z2_vocab.uc" <<'UCODE'
let s = require("diagnostics.fuzzer.strategies");
let fs = require("fs");

// function <name>(ctx, desync) in zapret-antidpi.lua, plus luaexec from
// zapret-lib.lua. The example/debug helpers are excluded on purpose.
const Z2_METHODS = [
    "dht_dn", "drop", "fake", "fakeddisorder", "fakedsplit", "hostfakesplit",
    "http_domcase", "http_hostcase", "http_methodeol", "http_unixeol",
    "luaexec", "multidisorder", "multidisorder_legacy", "multisplit", "oob",
    "pktmod", "rst", "send", "synack", "synack_split", "syndata", "tcpseg",
    "tls_client_hello_clone", "udplen", "wsize", "wssize"
];

// The "standard fooling" bullet list of zapret-antidpi.lua, plus badsum which
// reconstruct_opts() reads as desync.arg.badsum.
const Z2_FOOLING = [
    "fool", "ip_ttl", "ip6_ttl", "ip_autottl", "ip6_autottl", "ip6_hopbyhop",
    "ip6_hopbyhop2", "ip6_destopt", "ip6_destopt2", "ip6_routing", "ip6_ah",
    "tcp_seq", "tcp_ack", "tcp_ts", "tcp_ts_up", "tcp_md5", "tcp_flags_set",
    "tcp_flags_unset", "tcp_nop_del", "badsum"
];

// v1 fooling names, and what nfqws2 calls the same thing.
const V1_TO_Z2 = {
    badseq: "tcp_seq=1000000",
    badack: "tcp_ack=1000000",
    ts: "tcp_ts=-600000",
    md5sig: "tcp_md5",
    datanoack: "tcp_flags_unset=ack",
    fakedrop: ""
};

let errors = [];
let note = function(msg) { push(errors, msg); };

let check = function(id, args) {
    for (let m in match(args, /--lua-desync=([a-z_0-9]+)/g) || []) {
        if (index(Z2_METHODS, m[1]) < 0)
            note(id + ": no such zapret2 desync method '" + m[1] + "' in: " + args);
    }

    // fooling=<list> inside any --lua-desync method
    for (let fm in match(args, /fooling=([a-z_0-9,=-]+)/g) || []) {
        let list = fm[1];
        for (let name in split(list, ",")) {
            name = trim(name);
            if (name == "") continue;
            let key = split(name, "=")[0];
            if (index(Z2_FOOLING, key) >= 0) continue;
            if (type(V1_TO_Z2[key]) == "string")
                note(id + ": fooling '" + name + "' is a zapret v1 name and is silently ignored by nfqws2; use " + V1_TO_Z2[key] + " - in: " + args);
            else
                note(id + ": unknown zapret2 fooling '" + name + "': " + args);
        }
    }

    // tls_mod=<list> on the fake method: nfqws2 knows rnd,rndsni,sni=<str>
    for (let tm in match(args, /tls_mod=([a-z_0-9,=]+)/g) || []) {
        for (let name in split(tm[1], ",")) {
            name = trim(name);
            if (name == "" || index([ "rnd", "rndsni" ], name) >= 0) continue;
            if (match(name, /^sni=/) != null) continue;
            if (index([ "dupsid", "padencap", "notls" ], name) >= 0)
                note(id + ": tls_mod '" + name + "' is not in the nfqws2 tls_mod list (rnd,rndsni,sni=<str>): " + args);
        }
    }
};

for (let engine in [ "zapret2" ]) {
    let list = s.get_strategies_for_engine(engine, "presets", "discord_suite");
    if (length(list) == 0) {
        note("no zapret2 strategies returned");
        continue;
    }
    for (let st in list)
        check(engine + "/" + (st.id || st.name || "?"), st.args || "");
}

// Builtin presets ship as JSON and bypass get_strategies_for_engine filtering
// only when their blobs are present, so they are checked from the file too.
let raw = fs.readfile(ARGV[0]);
if (raw) {
    let parsed = json(raw);
    for (let st in (type(parsed.zapret2) == "array" ? parsed.zapret2 : []))
        check("preset/" + (st.id || "?"), st.args || "");
}

if (length(errors) > 0) {
    for (let e in errors) printf("%s\n", e);
    exit(1);
}
printf("zapret2 vocabulary ok\n");
UCODE

if out="$(ucode "$WORK_DIR/z2_vocab.uc" "$PRESETS" 2>&1)"; then
  printf 'fuzzer zapret2 vocabulary: %s\n' "$out"
else
  fail "zapret2 strategies name methods or fooling options that do not exist:
$out"
fi

printf 'PASS: fuzzer_zapret2_vocab\n'