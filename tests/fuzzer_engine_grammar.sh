#!/usr/bin/env bash
# Strategy arguments are engine-specific, and the engines do not share a grammar.
#
#   zapret2 : --lua-desync=<method>:<key>=<val>,...   methods live in the Lua library
#   zapret  : --dpi-desync=<method> --dpi-desync-<key>=<val>
#   byedpi  : --auto=<list> -s <pos> -o <n> --fake -1 --ttl <n>
#
# A flag from the wrong engine is not a syntax error anywhere: the other binary
# either ignores it or refuses to start, and the fuzzer reports it as a DPI
# failure. So the lists are checked against the grammar of their own engine, and
# the zapret2 methods are checked against the method table of the Lua library that
# actually ships with zapret2 (method names taken from that file, not from memory).
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

cat >"$WORK_DIR/engine_grammar.uc" <<'UCODE'
let s = require("diagnostics.fuzzer.strategies");

// Desync methods zapret2's Lua library defines. luaexec lives in zapret-lib.lua
// rather than zapret-antidpi.lua but is dispatched the same way.
// dht_dn drop fake fakeddisorder fakedsplit hostfakesplit http_domcase
// http_hostcase http_methodeol http_unixeol multidisorder multidisorder_legacy
// multisplit oob pktmod rst send synack synack_split syndata tcpseg
// tls_client_hello_clone udplen wsize wssize
const Z2_METHODS = [
    "dht_dn", "drop", "fake", "fakeddisorder", "fakedsplit", "hostfakesplit",
    "http_domcase", "http_hostcase", "http_methodeol", "http_unixeol",
    "multidisorder", "multidisorder_legacy", "multisplit", "oob", "pktmod",
    "rst", "send", "synack", "synack_split", "syndata", "tcpseg",
    "tls_client_hello_clone", "udplen", "wsize", "wssize", "luaexec"
];

let errors = [];
let note = function(msg) { push(errors, msg); };

for (let engine in ["zapret2", "zapret", "byedpi"]) {
    let list = s.get_strategies_for_engine(engine, "presets", "youtube_suite");
    if (length(list) == 0) {
        note(engine + ": no strategies returned");
        continue;
    }

    for (let st in list) {
        let args = st.args || "";
        let id = engine + "/" + (st.id || st.name || "?");

        if (index(args, "--dpi-desync=") >= 0 || index(args, "--dpi-desync-") >= 0) {
            if (engine == "zapret2")
                note(id + ": zapret v1 flag in a zapret2 strategy: " + args);
        }
        if (index(args, "--lua-desync=") >= 0) {
            if (engine != "zapret2")
                note(id + ": zapret2 flag in a " + engine + " strategy: " + args);
        }
        if (engine == "byedpi") {
            if (index(args, "--dpi-desync") >= 0 || index(args, "--lua-desync") >= 0)
                note(id + ": zapret flag in a byedpi strategy: " + args);
        }

        if (engine == "zapret2") {
            for (let m in match(args, /--lua-desync=([a-z_0-9]+)/g) || []) {
                if (index(Z2_METHODS, m[1]) < 0)
                    note(id + ": unknown zapret2 desync method '" + m[1] + "': " + args);
            }
        }
    }
}

if (length(errors) > 0) {
    for (let e in errors) printf("%s\n", e);
    exit(1);
}
printf("engine grammar ok\n");
UCODE

if out="$(ucode "$WORK_DIR/engine_grammar.uc" 2>&1)"; then
  printf 'fuzzer engine grammar: %s\n' "$out"
else
  fail "strategies use another engine's flags:
$out"
fi

printf 'PASS: fuzzer_engine_grammar\n'