#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# Pre-flight repair must handle nested outbound field errors (such as
# outbounds[2].tls.reality.support_x25519mlkem768: json: unknown field) as well as
# top-level fields and tachyon-core panic->fatal log level normalization.

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

# --- nested unknown field ----------------------------------------------------
CFG="$WORK_DIR/nested.json"
make_config "$CFG"
out="$(run_repair "$CFG" 'decode config at /tmp/x: outbounds[1].tls.reality.support_x25519mlkem768: json: unknown field "support_x25519mlkem768"')"
[ "$out" = "repaired" ] ||
  fail "nested unknown field must be repairable, got '$out'"
grep -q support_x25519mlkem768 "$CFG" &&
  fail "the nested field survived the repair"
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

grep -q support_x25519mlkem768 "$CFG4" || fail "a refused repair must leave the config alone"

# --- log level panic repair for tachyon-core ---------------------------------
CFG5="$WORK_DIR/panic_log.json"
cat >"$CFG5" <<'JSON'
{ "log": { "level": "panic", "timestamp": false }, "outbounds": [ { "type": "direct", "tag": "direct-out" } ] }
JSON
out="$(run_repair "$CFG5" 'check: create log factory: parse log level: unknown log level: panic')"
[ "$out" = "repaired" ] || fail "log level panic must be repaired to fatal, got '$out'"
grep -q '"level": "fatal"' "$CFG5" || fail "log.level was not changed to fatal"
grep -q '"panic"' "$CFG5" && fail "panic survived the repair"

printf 'tachyon-core unknown-field repair checks passed\n'
