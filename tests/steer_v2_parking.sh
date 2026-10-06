#!/usr/bin/env bash
# What spec v2 can no longer express must be parked, not silently degraded.
#
# Tachyon now writes only spec v2 (`version: 2`) and supports steer 2.0+. Two
# things did not survive that change, and both are the dangerous kind: a
# configuration that still looks applied but no longer does anything.
#
# 1. zapret2 strategies are Lua. contract-v1 stored `nfqws_bin`, the resolved
#    nfqws2 path, so steer launched the Lua-capable binary. v2 has no such key
#    and an unknown key rejects the whole spec, so it cannot be written at all.
#    The output still exists in v2 (`kind: zapret` + `strategy`) but runs the
#    wrong binary. Emitting it looks fine and silently drops the Lua part, so
#    the section has to be parked on steer - preserved in UCI, not applied.
#
# 2. urltest. Spec v2 expresses it as a `pick: latency` group, so steer *can*
#    express it - but the generator does not build those groups yet. Claiming
#    the capability before the generator exists would un-park urltest sections
#    and drop them from the spec with nothing to show for it.
#
# Both directions matter: parking something steer can do loses configuration the
# user had, and not parking something it cannot do loses it silently.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"
[ -f "$LIB_DIR/core/engine.uc" ] || fail "core/engine.uc not found"

out="$(ucode -L "$LIB_DIR" -e '
let e = require("core.engine");
for (let eng in [ "sing-box", "steer", "steer-extended" ]) {
    printf("%s zapret=%s lua=%s urltest=%s\n", eng,
        e.supports(eng, "outbound.zapret") ? "y" : "n",
        e.supports(eng, "outbound.zapret_lua") ? "y" : "n",
        e.supports(eng, "routing.urltest") ? "y" : "n");
}
' 2>&1)" || fail "could not read the capability table: $out"

# The whole matrix is compared in one shot against the expected text. Field by
# field it took six separate greps, which is six ways to mistype a field name and
# still have the test read like it was checking something.
#
#   sing-box    zapret=y  plain zapret is expressible and predates the split
#   sing-box    lua=y     it drives the nfqws2 binary itself
#   steer       lua=n     spec v2 has no nfqws_bin key, so the Lua strategy
#                          cannot be expressed and the section must be parked
#   steer       urltest=n a latency group measures outputs, not the nodes of one
#                          subscription - see the note below
expected_caps='sing-box zapret=y lua=y urltest=y
steer zapret=y lua=n urltest=n
steer-extended zapret=y lua=n urltest=n'

[ "$out" = "$expected_caps" ] || fail "capability matrix changed
got:
$out
expected:
$expected_caps"

# ─── urltest stays parked, and this is why ───────────────────────────────────
# Spec v2 does have `pick: latency`, which looks like the urltest analog. It is
# not, and that is worth pinning in a test rather than in a comment: a group
# measures its MEMBERS, members are outputs that have a device, and a sing-box
# urltest group is made of the individual nodes of one subscription - not
# outputs, with no name in the outputs namespace. Tachyon merges every provider
# of a section into one subscription file, so the section is a single tunnel and
# a latency group over it has one member, which measures nothing.
#
# So `routing.urltest` must stay absent from the steer capabilities (asserted by
# the matrix above). Un-parking it without a generator that emits one output per
# node would silently stop selecting by latency while the UI still says URLTest.

# And the generator must not pretend it did: a section whose urltest child sets
# interval/tolerance lands them on the group, so prove the group really has one
# member for a single-subscription section.
members="$(ucode -L "$LIB_DIR" -e '
let g = require("steer.generator");
g.set_vless_supported(true);
let section = { ".name": "auto", "action": "connection", "enabled": "1", "label": "Auto",
                "steer_sub_file": "/etc/steer/subs/a.txt", "node": "auto" };
section.steer_urltest_settings = [ { check_interval: "3m", tolerance: "50" } ];
print("members=" + length(g.build_spec_v2([ section ], {}).outputs.Auto.members) + "\n");
' 2>&1)" || fail "could not read the latency group members: $members"
grep -q '^members=1$' <<< "$members" \
  || fail "expected the documented single-member latency group, got: $members"

# The mapping itself: a zapret2 section must land on the Lua feature, or parking
# decides on an empty feature string and never parks anything.
mapped="$(ucode -L "$LIB_DIR" -e '
let st = require("components.engine_state");
printf("z2=%s\n", st.section_feature({ ".type": "section", "action": "zapret2" }));
printf("z1=%s\n", st.section_feature({ ".type": "section", "action": "zapret" }));
printf("conn=%s\n", st.section_feature({ ".type": "section", "action": "connection" }));
' 2>&1)" || fail "could not read the section feature mapping: $mapped"

grep -q '^z2=outbound.zapret_lua$' <<< "$mapped" \
  || fail "a zapret2 section must map to outbound.zapret_lua so the switch layer parks it on steer: $mapped"
grep -q '^z1=outbound.zapret$' <<< "$mapped" \
  || fail "a plain zapret section must map to outbound.zapret: $mapped"
grep -q '^conn=sections.outbound$' <<< "$mapped" \
  || fail "the section feature mapping changed shape for ordinary proxy sections: $mapped"

# And the generator must never write the key that does not exist any more. Match
# a real key or assignment, not the comments explaining why it is absent - an
# earlier version of this check tripped over its own explanation.
if grep -RqE 'nfqws_bin[[:space:]]*[:=]' "$LIB_DIR/steer/generator.uc"; then
  fail "nfqws_bin is back in the generator; it is not a spec v2 key and an unknown key rejects the whole spec"
fi

# The cleanup is driven from a file, not `ucode -e`: the same generator is what
# aborts the ucode process on some fixtures under `-e`.
cat >"$WORK_DIR/specclean.uc" <<'EOF'
let fs = require("fs");
let e = require("core.engine");
let dir = ARGV[0];
printf("removed=%d\n", length(e.remove_stale_steer_specs(dir)));
printf("yaml_left=%s\n", fs.stat(dir + "/spec.yaml") != null ? "yes" : "no");
printf("json_kept=%s\n", fs.stat(dir + "/spec.json") != null ? "yes" : "no");
printf("second_call_removed=%d\n", length(e.remove_stale_steer_specs(dir)));
EOF

# ─── exactly one spec file may exist ─────────────────────────────────────────
# steer refuses the directory when it finds both spec.json and spec.yaml: a
# rejection, not a precedence rule, because only the writer knows which one is
# real. Tachyon owns spec.json, so the other one is stale by definition and has
# to go before the new spec is written - a router that had one lying around would
# otherwise go from working to refusing to start.
spec_dir="$WORK_DIR/specs"
mkdir -p "$spec_dir"
printf 'version: 2\n' > "$spec_dir/spec.yaml"
printf 'stale json\n' > "$spec_dir/spec.json"

out="$(ucode -L "$LIB_DIR" "$WORK_DIR/specclean.uc" "$spec_dir" 2>&1)" \
  || fail "could not drive the stale spec cleanup: $out"
grep -q '^removed=1$' <<< "$out" \
  || fail "a leftover spec.yaml next to spec.json was not removed, and steer rejects the pair: $out"
grep -q '^yaml_left=no$' <<< "$out" \
  || fail "spec.yaml survived the cleanup: $out"
grep -q '^json_kept=yes$' <<< "$out" \
  || fail "the cleanup removed spec.json, which is the file Tachyon owns and writes: $out"
grep -q '^second_call_removed=0$' <<< "$out" \
  || fail "the cleanup is not idempotent; every apply would report a removal: $out"

printf 'fault: steer v2 parking checks passed\n'