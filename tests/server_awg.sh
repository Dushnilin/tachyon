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

# 1. Test sing-box configuration generation with AWG server (2.0, 3.0, and 3.1)
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
      "awg_version": "2.0",
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
    },
    {
      ".name": "my_awg30_server",
      ".type": "server",
      "enabled": "1",
      "protocol": "awg",
      "awg_version": "3.0",
      "awg_private_key": "aW5ib3VuZF9wcml2YXRlX2tleQ==",
      "awg_peer_public_key": "cGVlcl9wdWJsaWNfa2V5",
      "awg_server_address": "192.168.1.100",
      "awg_server_port": "51821",
      "awg_local_address": ["10.0.0.1/24"],
      "awg_jc": "6",
      "awg_jmin": "200",
      "awg_jmax": "600",
      "awg_s1": "20",
      "awg_s2": "30",
      "awg_h1": "100-200",
      "awg_h2": "300-400",
      "awg_h3": "500-600",
      "awg_h4": "700-800",
      "awg_header_protection_key": "dyBkZypS0O8PSlG0Ide3Agjp4Fng3YdYlPvXzZIldYQ=",
      "awg_content_padding_addition": "38-104"
    },
    {
      ".name": "my_awg31_server",
      ".type": "server",
      "enabled": "1",
      "protocol": "awg",
      "awg_version": "3.1",
      "awg_private_key": "aW5ib3VuZF9wcml2YXRlX2tleQ==",
      "awg_peer_public_key": "cGVlcl9wdWJsaWNfa2V5",
      "awg_server_address": "192.168.1.100",
      "awg_server_port": "51822",
      "awg_local_address": ["10.0.0.1/24"],
      "awg_jc": "6",
      "awg_jmin": "292",
      "awg_jmax": "743",
      "awg_s1": "28",
      "awg_s2": "130",
      "awg_s3": "53",
      "awg_s4": "25",
      "awg_h1": "179761265-179779753",
      "awg_h2": "1691691036-1691701489",
      "awg_h3": "2788983576-2789001884",
      "awg_h4": "3784650023-3784673067",
      "awg_header_protection_key": "dyBkZypS0O8PSlG0Ide3Agjp4Fng3YdYlPvXzZIldYQ=",
      "awg_content_padding_addition": "38-104",
      "awg_rekey_after_time": "107-132",
      "awg_rekey_timeout": "5-6",
      "awg_reject_after_time": "171-193",
      "awg_keepalive_timeout": "11-18",
      "awg_max_handshake_attempts": "15-24"
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

# Check AWG 3.0 server inbound
grep -q '"tag": "server-my_awg30_server-in"' "$out_json" || fail "sing-box config missing server-my_awg30_server-in tag"
grep -q '"header_protection_key": "dyBkZypS0O8PSlG0Ide3Agjp4Fng3YdYlPvXzZIldYQ="' "$out_json" || fail "AWG 3.0 server missing header_protection_key"
grep -q '"content_padding_addition": "38-104"' "$out_json" || fail "AWG 3.0 server missing content_padding_addition"

# Check AWG 3.1 server inbound
grep -q '"tag": "server-my_awg31_server-in"' "$out_json" || fail "sing-box config missing server-my_awg31_server-in tag"
grep -q '"rekey_after_time": "107-132"' "$out_json" || fail "AWG 3.1 server missing rekey_after_time"
grep -q '"rekey_timeout": "5-6"' "$out_json" || fail "AWG 3.1 server missing rekey_timeout"
grep -q '"reject_after_time": "171-193"' "$out_json" || fail "AWG 3.1 server missing reject_after_time"
grep -q '"keepalive_timeout": "11-18"' "$out_json" || fail "AWG 3.1 server missing keepalive_timeout"
grep -q '"max_handshake_attempts": "15-24"' "$out_json" || fail "AWG 3.1 server missing max_handshake_attempts"

printf 'AWG 2.0, 3.0, and 3.1 server configuration checks passed\n'
