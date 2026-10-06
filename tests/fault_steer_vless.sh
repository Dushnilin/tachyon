#!/usr/bin/env bash
# FAULT: a steer build without the vless client takes the whole spec down.
#
# The reported error is the engine's own:
#
#   Failed to generate the steer spec: spec_rejected: steer: outputs.main:
#   kind vless requires the steer-extended package
#
# Tachyon emitted a vless output for any section that had a steer_sub_file, with
# no check that the installed engine could compile it. In v2 that output is
# `kind: tunnel, protocol: vless` - `kind: vless` is itself rejected - so the
# failure mode survived the format change. engine.uc already has the
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
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"

[ -f "$LIB_DIR/steer/generator.uc" ] || fail "steer/generator.uc not found"

out="$(ucode -L "$LIB_DIR" -e '
let gen = require("steer.generator");
let section = { ".name": "main", "label": "main", "action": "subscription", "enabled": "1",
                "steer_sub_file": "/var/run/tachyon/steer/main.txt", "node": "auto" };
let settings = { "source_network_interfaces": [ "br-lan" ] };

// The stock build: no vless client.
gen.set_vless_supported(false);
let stock = gen.build_spec_v2([ section ], settings);
printf("stock_has_main=%s\n", stock.outputs["main"] != null ? "yes" : "no");
printf("stock_kind=%s\n", stock.outputs["main"] != null ? stock.outputs["main"].kind : "-");

// The extended build: the section keeps its tunnelled output. In v2 that is a
// tunnel, plus a group over it because the section auto-selects.
gen.set_vless_supported(true);
let ext = gen.build_spec_v2([ section ], settings);
printf("ext_has_main=%s\n", ext.outputs["main"] != null ? "yes" : "no");
printf("ext_kind=%s\n", ext.outputs["main"] != null ? ext.outputs["main"].kind : "-");
printf("ext_tun_kind=%s\n", ext.outputs["main-tun"] != null ? ext.outputs["main-tun"].kind : "-");
printf("ext_tun_proto=%s\n", ext.outputs["main-tun"] != null ? ext.outputs["main-tun"].protocol : "-");
' 2>&1)" || fail "could not drive the steer generator: $out"

# The invariant that matters: a spec the installed engine cannot compile must
# never be written. A stock build therefore gets no vless tunnel for the section -
# it falls back to direct, so the section still compiles and the rest of the spec
# survives. Dropping it entirely would be worse than degrading it.
stock_kind="$(printf '%s\n' "$out" | sed -n 's/^stock_kind=//p')"
[ "$stock_kind" = "tunnel" ] \
  && fail "a vless tunnel was still emitted for a build without the vless client - the engine rejects the whole spec over it: $out"
[ -n "$stock_kind" ] \
  || fail "the section vanished from the spec on a stock build instead of degrading: $out"

# And the extended build is untouched - the gate must not cost anyone their proxy.
[ "$(printf '%s\n' "$out" | sed -n 's/^ext_has_main=//p')" = "yes" ] \
  || fail "the vless section was dropped on an extended build that supports it: $out"
[ "$(printf '%s\n' "$out" | sed -n 's/^ext_kind=//p')" = "group" ] \
  || fail "an auto-selecting section must be a group in v2, got: $out"
[ "$(printf '%s\n' "$out" | sed -n 's/^ext_tun_kind=//p')" = "tunnel" ] \
  || fail "the extended build lost its tunnel output: $out"
[ "$(printf '%s\n' "$out" | sed -n 's/^ext_tun_proto=//p')" = "vless" ] \
  || fail "v2 must carry the protocol on the tunnel; `kind: vless` is rejected: $out"

# The capability probe must be wired into the spec path, not just the UI.
grep -Fq 'steer_has_extended_build' "$LIB_DIR/steer/generator.uc" \
  || fail "the steer spec path still does not ask whether the installed build has the vless client"

# steer_contract_ready() existed and was exported but called from nowhere.
called="$(grep -rl 'steer_contract_ready' "$LIB_DIR" | grep -v '/engine.uc$' || true)"
[ -n "$called" ] \
  || fail "steer_contract_ready() is still defined and never called - the engine can be older than our contract and we only find out when apply fails"

# --- switching between the two steer ids must not be a silent no-op ---------
# "steer" and "steer-extended" are the same binary and the same init script; they
# name a build, not a program. Switching between them used to change one UCI
# string, restart the service for nothing, and report success - so a user
# selecting a build got a restart and no change, and never learned why.
out="$(ucode -L "$LIB_DIR" -e '
let engine = require("core.engine");
printf("same_binary=%s\n", engine.engine_binary("steer") == engine.engine_binary("steer-extended") ? "yes" : "no");
printf("same_init=%s\n", engine.init_script_present("steer") == engine.init_script_present("steer-extended") ? "yes" : "no");
' 2>&1)" || fail "could not read the engine module: $out"

# The ids are interchangeable, which is exactly why the switch has to notice.
grep -q '^same_binary=yes$' <<< "$out" \
  || fail "steer and steer-extended no longer resolve to the same binary; the no-op guard below needs revisiting"
grep -q '^same_init=yes$' <<< "$out" \
  || fail "steer and steer-extended no longer resolve to the same init script; the no-op guard below needs revisiting"

grep -Fq 'already_active' "$LIB_DIR/service/engine_runtime_lib.uc" \
  || fail "switching to the engine that is already active with the same binary and init still runs a pointless switch and restart"

grep -Fq 'replace_build' "$LIB_DIR/service/engine_runtime_lib.uc" \
  || fail "there is no way to tell a deliberate rebuild from an accidental no-op switch"

# --- and the dead restore must stay dead -------------------------------------
# The snapshot was written to UCI, read back into a `restored` field, and never
# applied. Sections are not modified on disk - the generator skips them for the
# active engine - so there is nothing to restore, and the field only made API
# consumers believe otherwise.
# Definitions, not mentions: the comments that explain the removal are allowed to
# name the old functions, and an earlier version of this check tripped over them.
for dead in 'function read_parked(' 'function write_parked(' 'function unsupported_snapshot_key('; do
  if grep -RqF "$dead" "$LIB_DIR"; then
    fail "the parked-snapshot helper ($dead) is back; nothing consumes its result, so the field it feeds only misleads"
  fi
done
if grep -RqE 'restored:[[:space:]]*restored|restored,[[:space:]]*$' "$LIB_DIR/components/engine_state.uc"; then
  fail "apply_switch still returns a `restored` field that nothing applies"
fi

# The build must be reported as a fact, not as a note string in a corner.
grep -Fq 'matches_build' "$LIB_DIR/core/engine.uc" \
  || fail "detect() does not report whether the installed build is the one that was asked for"

# --- one section must not become two outputs -------------------------------
# Found on a router: a section named Zapret2 with label "Youtube" produced both
# "Zapret2" and "Youtube" outputs pointing at the same opts file. Each output
# costs the engine its own netfilter queue and a second steer-nfqws process
# running identical filters, and the phantom showed up in `steer outputs` as a
# target no config section backs. The channel builder resolves its target by
# label, so the label-named output is the one actually in use.
out="$(ucode -L "$LIB_DIR" -e '
let gen = require("steer.generator");
let section = { ".name": "Zapret2", "label": "Youtube", "action": "zapret2", "enabled": "1" };
gen.set_vless_supported(true);
let spec = gen.build_spec_v2([ section ], { "source_network_interfaces": [ "br-lan" ] });
let names = [];
for (let n in spec.outputs) push(names, n);
printf("outputs=%s\n", join(",", names));
// v2 renamed the opts_file key to strategy; the kind stays zapret.
printf("zkind=%s\n", spec.outputs["Youtube"] != null ? spec.outputs["Youtube"].kind : "-");
printf("zstrategy=%s\n", spec.outputs["Youtube"] != null && spec.outputs["Youtube"].strategy != null ? "yes" : "no");
' 2>&1)" || fail "could not drive the zapret output path: $out"

grep -q 'outputs=direct,Youtube$' <<< "$out" \
  || fail "a labelled zapret section did not produce exactly one output: $out"

if grep -q 'Zapret2' <<< "$out"; then
  fail "the section name was emitted as a second output alongside the label, giving one section two netfilter queues and two steer-nfqws processes running the same filters: $out"
fi

grep -q '^zkind=zapret$' <<< "$out" \
  || fail "zapret keeps its kind in v2; only the opts_file key became strategy: $out"
grep -q '^zstrategy=yes$' <<< "$out" \
  || fail "the nfqws strategy file must be named `strategy` in v2, `opts_file` is an unknown key and rejects the spec: $out"

# The channel target must resolve to the same name, or the output is unreachable.
# Not asserted here: channels are built from materialised list files, which do
# not exist outside a router, so the container cannot produce one. Verified on
# 192.168.1.205 instead - the live spec has channel Youtube_dom with out "Youtube"
# and no channel pointing at "Zapret2", so the label-named output is the one in
# use and the section-name form was the redundant one.

printf 'fault: steer vless capability and switch checks passed\n'