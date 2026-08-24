#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# ---- 1. Schema boundary helper (j1/j2/j3/itime removed in extended 2.6.1)
cat >"$WORK_DIR/check_schema.uc" <<'UC'
let common = require("core.common");
printf("%s", common.extended_awg_schema_has_junk_signatures(ARGV[1]) ? "yes" : "no");
UC

check() {
  ucode -L "$TACHYON_LIB" "$WORK_DIR/check_schema.uc" x "$1"
}

[ "$(check '1.13.16-extended-2.6.0')" = "yes" ] || fail "2.6.0 must still accept j1-j3/itime"
[ "$(check '1.13.14-extended-2.5.3')" = "yes" ] || fail "2.5.x must accept j1-j3/itime"
[ "$(check '1.13.16-extended-2.6.1')" = "no" ] || fail "2.6.1 removed j1-j3/itime"
[ "$(check '1.13.18-extended-2.6.5')" = "no" ] || fail "2.6.5 removed j1-j3/itime"
[ "$(check '1.3.0-extended-3.0.0')" = "no" ] || fail "3.x must not emit j1-j3/itime"
[ "$(check '1.12.0')" = "no" ] || fail "stock sing-box has no junk-signature fields"
[ "$(check '')" = "no" ] || fail "unknown version must not emit j1-j3/itime"

# ---- 2. Generator omits amnezia.j1 for extended 2.6.5 but keeps it for 2.6.0
make_fixture() {
  cat >"$WORK_DIR/awg_fixture.json" <<JSON
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
      "awg_j1": "<b 0x0102030405>",
      "awg_itime": "30"
    }
  ]
}
JSON
}

generate() {
  mkdir -p "$WORK_DIR/out.section-cache"
  SB_VERSION_STATE_FILE="$WORK_DIR/sing-box-version" \
    ucode -L "$TACHYON_LIB" "$TACHYON_LIB/singbox/generator.uc" generate-config-fixture \
    "$WORK_DIR/awg_fixture.json" "$WORK_DIR/singbox_awg.json" "127.0.0.1" 0 0
}

# 2.6.5: fields removed upstream -> must not appear in the generated config.
printf '1.13.18-extended-2.6.5\n' >"$WORK_DIR/sing-box-version"
make_fixture
generate
grep -q '"amnezia"' "$WORK_DIR/singbox_awg.json" || fail "extended endpoint must keep the amnezia object"
grep -q '"j1"' "$WORK_DIR/singbox_awg.json" && fail "generated config must not carry amnezia.j1 on extended 2.6.5"
grep -q '"itime"' "$WORK_DIR/singbox_awg.json" && fail "generated config must not carry amnezia.itime on extended 2.6.5"

# 2.6.0: schema still knows the fields -> they are emitted verbatim.
printf '1.13.16-extended-2.6.0\n' >"$WORK_DIR/sing-box-version"
make_fixture
generate
grep -q '"j1": "<b 0x0102030405>"' "$WORK_DIR/singbox_awg.json" || fail "extended 2.6.0 must keep amnezia.j1 with the tag template"
grep -q '"itime": 30' "$WORK_DIR/singbox_awg.json" || fail "extended 2.6.0 must keep amnezia.itime"

# ---- 3. Classic plain-hex i1 payloads are converted to the tag-chain format
# for every extended/lx build (userspace WireGuard ignores bare hex).
printf '1.13.18-extended-2.6.5\n' >"$WORK_DIR/sing-box-version"
cat >"$WORK_DIR/awg_fixture.json" <<JSON
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
      "awg_i1": "494e56495445207369703a626f62",
      "awg_i2": "<b 0x0102><r 12>",
      "awg_i3": ""
    }
  ]
}
JSON
generate
grep -q '"i1": "<b 0x494e56495445207369703a626f62>"' "$WORK_DIR/singbox_awg.json" ||
  fail "plain-hex awg_i1 must be wrapped into a <b 0x..> tag"
grep -q '"i2": "<b 0x0102><r 12>"' "$WORK_DIR/singbox_awg.json" ||
  fail "existing tag chains must pass through verbatim"
grep -q '"i3"' "$WORK_DIR/singbox_awg.json" && fail "empty cps options must stay absent"

printf 'AWG variant schema checks passed\n'
