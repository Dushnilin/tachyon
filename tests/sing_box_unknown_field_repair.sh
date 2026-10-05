#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# Switching sing-box variants could never complete when a config carried a field
# the target binary does not know. Reality support_x25519mlkem768 is the case
# that actually happens: sing-box-extended 2.7.2+ writes it into tls.reality,
# sing-box-lx rejects it as an unknown field.
#
# The pre-flight already tries to cope - it regenerates a candidate config for
# the binary being installed and then strips fields the candidate refuses, up to
# four times. That repair could not cope: the pattern only matched a single path
# segment after the index, so
#   outbounds[2].tls.reality.support_x25519mlkem768: json: unknown field
# never matched, and even on a match it only deleted a top-level key. The repair
# returned false, the install was refused, and the user got
#   Pre-flight check failed: ... unknown field "support_x25519mlkem768"

VERIFIER_UC="$ROOT_DIR/tachyon/files/usr/lib/components/verifier.uc"
LIB_DIR="$ROOT_DIR/tachyon/files/usr/lib"

cat >"$WORK_DIR/repair_drv.uc" <<'UC'
let verifier = require("components.verifier");
print(verifier.repair_unknown_outbound_field(ARGV[0], ARGV[1]) ? "repaired" : "refused");
UC

# fixture: two outbounds, the second one carrying the nested field
make_config() {
  cat >"$1" <<'JSON'
{
  "outbounds": [
    { "type": "direct", "tag": "direct-out" },
    {
      "type": "vless",
      "tag": "probe",
      "server": "127.0.0.1",
      "tls": {
        "enabled": true,
        "reality": {
          "enabled": true,
          "public_key": "Pb4rE8j1SlqZ5Y5g4xkZ9mKqYb1l0dQWc0h8HqQ0xkA",
          "short_id": "0123456789abcdef",
          "support_x25519mlkem768": true
        }
      }
    }
  ]
}
JSON
}

run_repair() {
  ucode -L "$LIB_DIR" "$WORK_DIR/repair_drv.uc" "$1" "$2"
}

# --- the reported failure ----------------------------------------------------
CFG="$WORK_DIR/nested.json"
make_config "$CFG"
out="$(run_repair "$CFG" 'decode config at /tmp/x: outbounds[1].tls.reality.support_x25519mlkem768: json: unknown field "support_x25519mlkem768"')"
[ "$out" = "repaired" ] ||
  fail "nested unknown field must be repairable, got '$out'"
grep -q support_x25519mlkem768 "$CFG" &&
  fail "the nested field survived the repair"
# The rest of the outbound has to survive, otherwise the repair just destroys the
# config instead of making it loadable.
grep -q '"public_key"' "$CFG" || fail "repair dropped unrelated reality fields"
grep -q '"direct-out"' "$CFG" || fail "repair dropped an unrelated outbound"
grep -q '"probe"' "$CFG" || fail "repair dropped the outbound it was fixing"

# Three segments deep, as the real error has.
CFG2="$WORK_DIR/deep.json"
make_config "$CFG2"
out="$(run_repair "$CFG2" 'outbounds[1].tls.reality.support_x25519mlkem768: json: unknown field "support_x25519mlkem768"')"
[ "$out" = "repaired" ] || fail "three-segment path must be repairable, got '$out'"

# --- regression: a top-level field still gets repaired ------------------------
CFG3="$WORK_DIR/toplevel.json"
cat >"$CFG3" <<'JSON'
{ "outbounds": [ { "type": "direct", "tag": "a", "bogus_field": true }, { "type": "direct", "tag": "b" } ] }
JSON
out="$(run_repair "$CFG3" 'outbounds[0].bogus_field: json: unknown field "bogus_field"')"
[ "$out" = "repaired" ] || fail "top-level unknown field must still be repairable, got '$out'"
grep -q bogus_field "$CFG3" && fail "the top-level field survived the repair"
grep -q '"tag": "a"' "$CFG3" || fail "repair dropped an unrelated key of the same outbound"

# --- refusals: nothing to repair, or something ambiguous ---------------------
CFG4="$WORK_DIR/refuse.json"
make_config "$CFG4"
out="$(run_repair "$CFG4" 'outbounds[9].tls.reality.nope: json: unknown field "nope"')"
[ "$out" = "refused" ] || fail "an out-of-range index must be refused, got '$out'"

out="$(run_repair "$CFG4" 'outbounds[0].tls.reality.not_there: json: unknown field "not_there"')"
[ "$out" = "refused" ] || fail "a field that is not present must be refused, got '$out'"

out="$(run_repair "$CFG4" 'decode config at /tmp/x: outbounds[1]: missing field "transport"')"
[ "$out" = "refused" ] || fail "an unrelated parse error must be refused, got '$out'"

out="$(run_repair "$CFG4" '')"
[ "$out" = "refused" ] || fail "an empty reason must be refused, got '$out'"

# The refusal cases must not have modified the file.
grep -q support_x25519mlkem768 "$CFG4" || fail "a refused repair must leave the config alone"

printf 'sing-box unknown-field repair checks passed\n'