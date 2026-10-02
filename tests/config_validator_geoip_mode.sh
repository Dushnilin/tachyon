#!/usr/bin/env bash
# The GeoIP mode is validated in config/validator.uc against a list that lives in
# config/connections.uc, and validator.uc reaches it through the module's export
# table. When that table did not carry the list, connections.GEOIP_COUNTRY_MODES
# was null on the other side of the require, validator.uc's own contains() helper
# returned false for null, and every section with a geoip_mode was rejected -
# including "exclude" and "include", the two values that had existed all along.
#
# That is not a cosmetic rejection: /etc/init.d/tachyon start aborts on it, so
# after an update the service simply did not come up and no section action ran.
# The generator path kept working the whole time, which is why the geoip
# generator test stayed green.
#
# This test drives the validator the same way init.d does, for all four values.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -z "$TACHYON_LIB" ]; then
  if [ -d "$ROOT_DIR/tachyon/files/usr/lib/config" ]; then
    TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
  else
    TACHYON_LIB="/usr/lib/tachyon"
  fi
fi

VALIDATOR="$TACHYON_LIB/config/validator.uc"
[ -f "$VALIDATOR" ] || fail "config/validator.uc not found at $VALIDATOR"

pass_count=0
ok() { pass_count=$((pass_count + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# --- 1. the list has to survive the module boundary -----------------------
# The exact defect: exported as null, contains() folds over nothing and every
# value looks invalid. Assert the array itself, not just that it is truthy.
exported="$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" -e '
let c = require("config.connections");
let modes = c.GEOIP_COUNTRY_MODES;
if (type(modes) != "array") print("not-an-array"); else print(join(",", modes));
' 2>/dev/null)" || true

[ "$exported" = "include,exclude,include_all,exclude_direct" ] ||
  fail "connections.GEOIP_COUNTRY_MODES must be exported as an array of the four modes, got '$exported'"
ok

# --- 2. all four modes must pass runtime validation -----------------------
write_fixture() {
  local path="$1" mode="$2"
  cat >"$path" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ]
  },
  "section": [
    {
      ".name": "geo",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"geo-out\"}" ],
      "geoip_country": [ "ru" ],
      "geoip_mode": "$mode"
    }
  ]
}
JSON
}

for mode in include exclude include_all exclude_direct; do
  write_fixture "$WORK_DIR/ok-$mode.json" "$mode"
  if ! TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$VALIDATOR" \
      validate-runtime-fixture "$WORK_DIR/ok-$mode.json" '{}' >"$WORK_DIR/$mode.out" 2>&1; then
    fail "GeoIP mode '$mode' must validate, but init.d would abort: $(tail -2 "$WORK_DIR/$mode.out" | tr '\n' ' ')"
  fi
  ok
done

# --- 3. and an unknown one must still be rejected ------------------------
write_fixture "$WORK_DIR/bad.json" "nonsense"
if TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$VALIDATOR" \
    validate-runtime-fixture "$WORK_DIR/bad.json" '{}' >"$WORK_DIR/bad.out" 2>&1; then
  fail "an unknown GeoIP mode must be rejected"
fi
grep -Fq "invalid GeoIP filter mode" "$WORK_DIR/bad.out" ||
  fail "unknown mode should say so, got: $(tail -2 "$WORK_DIR/bad.out" | tr '\n' ' ')"
ok

printf 'geoip mode validation: %d checks passed\n' "$pass_count"
printf 'PASS: config_validator_geoip_mode\n'