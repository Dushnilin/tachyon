#!/usr/bin/env bash
# Verifies sing-box variant switch pre-flight behavior:
# 1. repair_unknown_outbound_field handles endpoints[N] (such as amnezia)
# 2. check_sing_box_config_with_binary regenerates candidate configuration
#    for the target variant rather than testing the obsolete config on disk.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -z "$TACHYON_LIB" ]; then
  if [ -d "$ROOT_DIR/tachyon/files/usr/lib/components" ]; then
    TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
  else
    TACHYON_LIB="/usr/lib/tachyon"
  fi
fi

ucode() { command ucode -L "$TACHYON_LIB" "$@"; }

VERIFIER="$TACHYON_LIB/components/verifier.uc"
[ -f "$VERIFIER" ] || fail "missing $VERIFIER"

pass_count=0
ok() { pass_count=$((pass_count + 1)); }

# Test 1: repair_unknown_outbound_field on endpoints[0].amnezia
cat >"$WORK_DIR/endpoint_cfg.json" <<'JSON'
{
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "awg-ep",
      "amnezia": {
        "jc": 4,
        "jmin": 40,
        "jmax": 70,
        "s1": 20
      }
    }
  ]
}
JSON

cat >"$WORK_DIR/test_ep_repair.uc" <<'UCODE'
let fs = require("fs");
let v = require("components.verifier");

let file = ARGV[0];
let reason = ARGV[1];
let expected = ARGV[2] == "true";

let changed = v.repair_unknown_outbound_field(file, reason);
if (changed !== expected) {
    printf("repair(%s) returned %s, expected %s\n", reason, changed, expected);
    exit(1);
}
UCODE

if out="$(ucode "$WORK_DIR/test_ep_repair.uc" "$WORK_DIR/endpoint_cfg.json" \
  'endpoints[0].amnezia: json: unknown field "amnezia"' true 2>&1)"; then ok; else
  fail "endpoints[0].amnezia must be repairable: $out"
fi

# amnezia field must be deleted
if grep -q '"amnezia"' "$WORK_DIR/endpoint_cfg.json"; then
  fail "amnezia field was reported as removed but is still in config"
fi
ok

# but its inner properties (jc, jmin, jmax, s1) should be flattened onto the endpoint root
for prop in '"jc": 4' '"jmin": 40' '"jmax": 70' '"s1": 20'; do
  if ! grep -q "$prop" "$WORK_DIR/endpoint_cfg.json"; then
    fail "flattened property $prop missing from repaired endpoint: $(cat "$WORK_DIR/endpoint_cfg.json")"
  fi
  ok
done

# Second repair run returns false (idempotent)
if out="$(ucode "$WORK_DIR/test_ep_repair.uc" "$WORK_DIR/endpoint_cfg.json" \
  'endpoints[0].amnezia: json: unknown field "amnezia"' false 2>&1)"; then ok; else
  fail "already repaired endpoint must return false: $out"
fi

# Test 2: Inbounds unknown field repair
cat >"$WORK_DIR/inbound_cfg.json" <<'JSON'
{
  "inbounds": [
    {
      "type": "tproxy",
      "tag": "tproxy-in",
      "unknown_prop": "val"
    }
  ]
}
JSON

if out="$(ucode "$WORK_DIR/test_ep_repair.uc" "$WORK_DIR/inbound_cfg.json" \
  'inbounds[0].unknown_prop: json: unknown field "unknown_prop"' true 2>&1)"; then ok; else
  fail "inbounds[0].unknown_prop must be repairable: $out"
fi

if grep -q '"unknown_prop"' "$WORK_DIR/inbound_cfg.json"; then
  fail "inbound unknown_prop was reported as removed but is still present"
fi
ok

# Test 3: check_sing_box_config_with_binary signature and variant switch branch
body="$(sed -n '/^function check_sing_box_config_with_binary/,/^}/p' "$VERIFIER")"
[ -n "$body" ] || fail "check_sing_box_config_with_binary not found"

if ! grep -q 'target_variant' <<<"$body"; then
  fail "check_sing_box_config_with_binary must accept target_variant"
fi
ok

if ! grep -q 'is_variant_switch' <<<"$body"; then
  fail "check_sing_box_config_with_binary must detect variant switch"
fi
ok

if ! grep -q 'SB_VARIANT_STATE_FILE' <<<"$body"; then
  fail "candidate generation must set SB_VARIANT_STATE_FILE"
fi
ok

printf 'sing-box variant switch preflight: %d checks passed\n' "$pass_count"
printf 'PASS: sing_box_variant_switch_preflight\n'
