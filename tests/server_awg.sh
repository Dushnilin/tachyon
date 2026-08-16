#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
TACHYON_BIN="$ROOT_DIR/tachyon/files/usr/bin/tachyon"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# 1. Test sing-box configuration generation with AWG server
cat >"$WORK_DIR/awg_fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1"
  },
  "server": [
    {
      ".name": "my_awg_server",
      ".type": "server",
      "enabled": "1",
      "protocol": "awg",
      "awg_private_key": "aW5ib3VuZF9wcml2YXRlX2tleQ==",
      "awg_peer_public_key": "cGVlcl9wdWJsaWNfa2V5",
      "awg_server_address": "192.168.1.100",
      "awg_server_port": "51820",
      "awg_local_address": ["10.0.0.1/24"],
      "awg_jc": "5",
      "awg_jmin": "50",
      "awg_jmax": "80",
      "awg_s1": "15",
      "awg_s2": "25",
      "awg_h1": "100",
      "awg_h2": "200",
      "awg_h3": "300",
      "awg_h4": "400"
    }
  ],
  "section": [
    {
      ".name": "default_direct",
      ".type": "section",
      "enabled": "1",
      "action": "bypass"
    }
  ]
}
JSON

mkdir -p "$WORK_DIR/out.section-cache"
out_json="$WORK_DIR/singbox_awg.json"

ucode -L "$TACHYON_LIB" "$TACHYON_LIB/singbox/generator.uc" generate-config-fixture \
  "$WORK_DIR/awg_fixture.json" "$out_json" "127.0.0.1" 0 0

grep -q '"type": "wireguard"' "$out_json" || fail "sing-box config missing wireguard inbound"
grep -q '"tag": "server-my_awg_server-in"' "$out_json" || fail "sing-box config missing server-my_awg_server-in tag"
grep -q '"jc": 5' "$out_json" || fail "sing-box config missing amnezia jc parameter"
grep -q '"s1": 15' "$out_json" || fail "sing-box config missing amnezia s1 parameter"
grep -q '"h1": 100' "$out_json" || fail "sing-box config missing amnezia h1 parameter"

printf 'AWG server configuration checks passed\n'
