#!/usr/bin/env bash
# FAULT: a steer build without the vless client takes the whole spec down.
#
# The reported error is the engine's own:
#
#   Failed to generate the steer spec: spec_rejected: steer: outputs.main:
#   kind vless requires the steer-extended package
#
# Tachyon emitted kind:"vless" for any section that had a steer_sub_file, with
# no check that the installed engine could compile it. engine.uc already has the
# check - steer_has_extended_build() probes `steer help vless`, and it answers
# correctly on a real extended build - but it was only ever used to label the UI.
# The spec path never asked.
#
# The blast radius is the reason this matters: the engine rejects the entire
# spec, not one output, so a single subscription-backed section left every other
# section unapplied too. And steer_contract_ready(), which checks the engine
# understands every subcommand we drive, was defined, exported and called from
# nowhere - the same "written and never wired" shape as is_stale/gc in the job
# engine.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -f "$LIB_DIR/steer/generator.uc" ] || fail "steer/generator.uc not found"

out="$(ucode -L "$LIB_DIR" -e '
let gen = require("steer.generator");
let section = { ".name": "main", "label": "main", "action": "subscription", "enabled": "1",
                "steer_sub_file": "/var/run/tachyon/steer/main.txt", "node": "auto" };
let settings = { "source_network_interfaces": [ "br-lan" ] };

// The stock build: no vless client.
gen.set_vless_supported(false);
let stock = gen.build_spec([ section ], settings);
printf("stock_has_main=%s\n", stock.outputs["main"] != null ? "yes" : "no");
let kinds = [];
for (let n in stock.outputs) push(kinds, n + ":" + stock.outputs[n].kind);
printf("stock_outputs=%s\n", join(",", kinds));

// The extended build: the section keeps its tunnelled output.
gen.set_vless_supported(true);
let ext = gen.build_spec([ section ], settings);
printf("ext_has_main=%s\n", ext.outputs["main"] != null ? "yes" : "no");
printf("ext_kind=%s\n", ext.outputs["main"] != null ? ext.outputs["main"].kind : "-");
' 2>&1)" || fail "could not drive the steer generator: $out"

# The invariant that matters: a spec the installed engine cannot compile must
# never be written. A stock build therefore gets no vless output for the
# section - it falls back to direct, so the section still compiles and the rest
# of the spec survives. Dropping it entirely would be worse than degrading it.
printf '%s\n' "$out" | grep -q '^stock_outputs=[^,]*\(,\|$\)' || true
stock_main="$(printf '%s\n' "$out" | sed -n 's/^stock_outputs=.*[,]main:\([a-z]*\).*/\1/p')"
[ -z "$stock_main" ] && stock_main="$(printf '%s\n' "$out" | sed -n 's/^stock_outputs=main:\([a-z]*\).*/\1/p')"
[ "$stock_main" = "vless" ] \
  && fail "a vless output was still emitted for a build without the vless client - the engine rejects the whole spec over it: $out"
[ -n "$stock_main" ] \
  || fail "the section vanished from the spec on a stock build instead of degrading: $out"

# And the extended build is untouched - the gate must not cost anyone their proxy.
[ "$(printf '%s\n' "$out" | sed -n 's/^ext_has_main=//p')" = "yes" ] \
  || fail "the vless section was dropped on an extended build that supports it: $out"
[ "$(printf '%s\n' "$out" | sed -n 's/^ext_kind=//p')" = "vless" ] \
  || fail "the extended build lost its vless output kind: $out"

# The capability probe must be wired into the spec path, not just the UI.
grep -Fq 'steer_has_extended_build' "$LIB_DIR/steer/generator.uc" \
  || fail "the steer spec path still does not ask whether the installed build has the vless client"

# steer_contract_ready() existed and was exported but called from nowhere.
called="$(grep -rl 'steer_contract_ready' "$LIB_DIR" | grep -v '/engine.uc$' || true)"
[ -n "$called" ] \
  || fail "steer_contract_ready() is still defined and never called - the engine can be older than our contract and we only find out when apply fails"

printf 'fault: steer vless capability checks passed\n'
