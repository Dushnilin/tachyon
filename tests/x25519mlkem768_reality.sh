#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# support_x25519mlkem768 in tls.reality tells a client to offer the hybrid
# X25519MLKEM768 key share, which Xray-core 26.9.x+ servers expect.
#
# Tachyon used to inject `true` into every Reality outbound whenever the running
# build was sing-box-extended >= 2.7.2. Two things broke because of that guess:
# sing-box-lx and stock sing-box reject the field outright, which is why an
# extended -> lx switch died in pre-flight with
#   outbounds[N].tls.reality.support_x25519mlkem768: json: unknown field
# and a server doing plain X25519 cannot complete a handshake that demands the
# hybrid exchange.
#
# The field is now carried only when the link actually asks for it. Explicit
# values are preserved, both spellings are accepted, and nothing is invented.
# This drives the real generator over a fixture, so it tests shipped code rather
# than a copy of it.

LIB_DIR="$TACHYON_LIB"
GENERATOR="$LIB_DIR/singbox/generator.uc"

reality_link() {
  # $1 tag suffix, $2 extra query string
  printf 'vless://00000000-0000-0000-0000-00000000000%s@example.net:443?encryption=none&security=reality&sni=example.net&fp=chrome&pbk=key&sid=ab&type=tcp&%s#n%s' \
    "$1" "$2" "$1"
}

cat >"$WORK_DIR/mlkem-fixture.json" <<JSON
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": "1.1.1.1", "service_listen_address": "127.0.0.1" },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "domain_suffix": [ "example.org" ],
      "selector_proxy_links_text": "$(reality_link 1 '&support_x25519mlkem768=1')\n$(reality_link 2 '&supportX25519MLKEM768=1')\n$(reality_link 3 '&support_x25519mlkem768=0')\n$(reality_link 4 '')"
    }
  ]
}
JSON

OUT="$WORK_DIR/mlkem-config.json"
if ! ucode -L "$LIB_DIR" "$GENERATOR" generate-config-fixture \
  "$WORK_DIR/mlkem-fixture.json" "$OUT" '127.0.0.1' '0' '0' >"$WORK_DIR/gen.log" 2>&1; then
  fail "generate-config-fixture failed: $(tail -3 "$WORK_DIR/gen.log")"
fi
[ -s "$OUT" ] || fail "the generator produced no config"

cat >"$WORK_DIR/check_mlkem.uc" <<'UC'
let fs = require("fs");
let common = require("core.common");
let as_string = common.as_string;
let cfg = json(fs.readfile(ARGV[0]));
let out = {};
for (let ob in cfg.outbounds) {
  if (type(ob) != "object" || type(ob.tls) != "object" || type(ob.tls.reality) != "object")
    continue;
  let name = as_string(ob.remark || ob.tag || "");
  // Record presence separately from value: absent and false are different.
  out[name] = exists(ob.tls.reality, "support_x25519mlkem768")
    ? (ob.tls.reality.support_x25519mlkem768 === true ? "true" : "false")
    : "absent";
}
printf("%J\n", out);
UC

result="$(ucode -L "$LIB_DIR" "$WORK_DIR/check_mlkem.uc" "$OUT")" ||
  fail "could not inspect the generated reality outbounds"

expect() {
  local n="$1"
  local want="$2"
  local got
  got="$(printf '%s' "$result" | grep -o "\"proxy-$n-out\": \"[a-z]*\"" | head -1 | sed 's/.*: "\([a-z]*\)"/\1/')"
  [ -n "$got" ] || fail "no reality outbound proxy-$n-out in the generated config ($result)"
  [ "$got" = "$want" ] ||
    fail "outbound proxy-$n-out: expected support_x25519mlkem768=$want, got '$got'"
}

# Explicitly requested, in either spelling.
expect 1 "true"
expect 2 "true"
# An explicit false is a decision, not an absence.
expect 3 "false"
# Absent in the link means absent in the config: no inventing it.
expect 4 "absent"

# Nothing anywhere may be flagged unless a link asked for it.
total="$(printf '%s' "$result" | grep -o '"true"' | wc -l)"
[ "$total" -eq 2 ] ||
  fail "exactly the two links that asked for the flag may set it, found $total"

printf 'x25519mlkem768 explicit-flag checks passed\n'