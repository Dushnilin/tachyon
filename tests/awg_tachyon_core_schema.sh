#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# tachyon-core takes the AWG params flat on wireguard endpoints (no "amnezia"
# wrapper) and converts plain-hex CPS i1 payloads into <b 0x..> tag chains.

generate() {
  mkdir -p "$WORK_DIR/out.section-cache"
  TACHYON_CORE_VERSION_FILE="$WORK_DIR/tachyon-core-version" \
    ucode -L "$TACHYON_LIB" "$TACHYON_LIB/tachyon_core/generator.uc" generate-config-fixture \
    "$WORK_DIR/awg_fixture.json" "$WORK_DIR/tachyon_awg.json" "127.0.0.1" 0 0
}

printf '0.5.7\n' >"$WORK_DIR/tachyon-core-version"

# ---- 1. Plain-hex i1 payloads are converted to tag-chain format; existing tag
# chains pass through verbatim; empty CPS options stay absent.
cat >"$WORK_DIR/awg_fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1"
  },
  "section": [
    {
      ".name": "my_awg",
      ".type": "section",
      "enabled": "1",
      "action": "awg",
      "awg_private_key": "aW5ib3VuZF9wcml2YXRlX2tleQ==",
      "awg_peer_public_key": "cGVlcl9wdWJsaWNfa2V5",
      "awg_server_address": "192.168.1.100",
      "awg_server_port": "51820",
      "awg_local_address": ["10.0.0.1/24"],
      "awg_jc": "4",
      "awg_jmin": "40",
      "awg_jmax": "70",
      "awg_h1": "1",
      "awg_i1": "494e56495445207369703a626f62",
      "awg_i2": "<b 0x0102><r 12>",
      "awg_i3": ""
    }
  ]
}
JSON

generate
grep -q '"amnezia"' "$WORK_DIR/tachyon_awg.json" &&
  fail "tachyon-core endpoint must not carry an amnezia object"
grep -q '"jc": 4' "$WORK_DIR/tachyon_awg.json" ||
  fail "tachyon-core endpoint must carry jc flat"
grep -q '"h1": 1' "$WORK_DIR/tachyon_awg.json" ||
  fail "tachyon-core endpoint must carry h1 flat"
grep -q '"i1": "<b 0x494e56495445207369703a626f62>"' "$WORK_DIR/tachyon_awg.json" ||
  fail "plain-hex awg_i1 must be wrapped into a <b 0x..> tag"
grep -q '"i2": "<b 0x0102><r 12>"' "$WORK_DIR/tachyon_awg.json" ||
  fail "existing tag chains must pass through verbatim"
grep -q '"i3"' "$WORK_DIR/tachyon_awg.json" &&
  fail "empty cps options must stay absent"
grep -q '"type": "wireguard"' "$WORK_DIR/tachyon_awg.json" ||
  fail "awg stays a wireguard endpoint for tachyon-core"

printf 'AWG tachyon-core schema checks passed\n'
