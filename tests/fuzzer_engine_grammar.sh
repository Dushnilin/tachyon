#!/usr/bin/env bash
# Native tachyon-core desync strategies use key=value syntax (preset=<name> or
# mode=<mode> split_pos=<pos> fooling=<fooling> ...). Removed external engine
# flags (--lua-desync, --dpi-desync, -s/-d/--auto) must not appear.
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
let r = require("diagnostics.fuzzer_runner");

let errors = [];
let note = function(msg) { push(errors, msg); };

let list = s.get_strategies_for_engine("desync", "presets", "youtube_suite");
if (length(list) == 0)
    note("desync: no strategies returned");

for (let st in list) {
    let args = st.args || "";
    let id = "desync/" + (st.id || st.name || "?");

    if (st.engine && st.engine != "desync")
        note(id + ": unexpected engine '" + st.engine + "'");

    if (index(args, "--dpi-desync") >= 0 || index(args, "--lua-desync") >= 0 || match(args, /(^| )-[sdfo][ 0-9]/))
        note(id + ": legacy external engine flag in desync strategy: " + args);

    if (!r.validate_strategy_args("desync", args))
        note(id + ": failed validate_strategy_args('desync'): " + args);

    let parsed = r.parse_desync_outbound(args, "test-desync-out");
    if (!parsed || parsed.type != "desync")
        note(id + ": failed parse_desync_outbound: " + args);
}

for (let old_eng in ["zapret2", "zapret", "byedpi"]) {
    let old_list = s.get_strategies_for_engine(old_eng, "presets", "youtube_suite");
    if (length(old_list) > 0)
        note(old_eng + ": removed engine unexpectedly returned " + length(old_list) + " strategies");
}

if (length(errors) > 0) {
    for (let e in errors) printf("%s\n", e);
    exit(1);
}
printf("desync engine grammar ok (%d strategies)\n", length(list));
UCODE

if out="$(ucode "$WORK_DIR/engine_grammar.uc" 2>&1)"; then
  printf 'fuzzer engine grammar: %s\n' "$out"
else
  fail "desync strategy grammar check failed:
$out"
fi

printf 'PASS: fuzzer_engine_grammar\n'