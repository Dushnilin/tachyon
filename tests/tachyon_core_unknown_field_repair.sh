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

# --- humanized tachyon-core unknown-field diagnostics (without "json: ") ----
CFG6="$WORK_DIR/tachyon_route_tcp_profile.json"
cat >"$CFG6" <<'JSON'
{ "route": { "tcp_profile": "low_latency", "final": "direct-out" }, "outbounds": [ { "type": "direct", "tag": "direct-out" } ] }
JSON
out="$(run_repair "$CFG6" 'check: route: tcp_profile: unknown field "tcp_profile"')"
[ "$out" = "repaired" ] || fail "humanized route: tcp_profile unknown field must be repaired, got '$out'"
grep -q '"tcp_profile"' "$CFG6" && fail "route.tcp_profile survived repair"
grep -q '"final": "direct-out"' "$CFG6" || fail "repair dropped route.final"

CFG7="$WORK_DIR/tachyon_nested_humanized.json"
make_config "$CFG7"
out="$(run_repair "$CFG7" 'check: outbounds[1].tls.reality.support_x25519mlkem768: unknown field "support_x25519mlkem768"')"
[ "$out" = "repaired" ] || fail "humanized nested outbound field must be repaired, got '$out'"
grep -q support_x25519mlkem768 "$CFG7" && fail "nested field survived humanized repair"

CFG8="$WORK_DIR/tachyon_toplevel_humanized.json"
cat >"$CFG8" <<'JSON'
{ "outbounds": [ { "type": "direct", "tag": "a", "bogus_field": true } ] }
JSON
out="$(run_repair "$CFG8" 'check: outbounds[0].bogus_field: unknown field "bogus_field"')"
[ "$out" = "repaired" ] || fail "humanized top-level outbound field must be repaired, got '$out'"
grep -q bogus_field "$CFG8" && fail "top-level field survived humanized repair"

CFG9="$WORK_DIR/tachyon_log_humanized.json"
cat >"$CFG9" <<'JSON'
{ "log": { "level": "warn", "extra_key": "x" }, "outbounds": [ { "type": "direct", "tag": "direct-out" } ] }
JSON
out="$(run_repair "$CFG9" 'check: log: extra_key: unknown field "extra_key"')"
[ "$out" = "repaired" ] || fail "humanized log unknown field must be repaired, got '$out'"
grep -q extra_key "$CFG9" && fail "log.extra_key survived humanized repair"
grep -q '"level": "warn"' "$CFG9" || fail "repair dropped log.level"

printf 'tachyon-core unknown-field repair checks passed\n'
