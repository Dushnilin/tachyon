#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
ucode() {
  command ucode -L "$TACHYON_LIB" "$@"
}
PARSER="$ROOT_DIR/tachyon/files/usr/lib/subscription/parser.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

normalize() {
  local input="$1"
  local output="$2"
  ucode "$PARSER" normalize-content "$input" "$output"
}

# A subscription served to a "Happ" User-Agent arrives as an Xray config, and
# the Hysteria2 obfuscation is carried in streamSettings.finalmask rather than
# in hysteriaSettings. Losing it means the salamander handshake is never sent,
# the server discards every QUIC packet and the node is reported as dead.
masked_input="$WORK_DIR/xray-hy2-finalmask.json"
masked_output="$WORK_DIR/xray-hy2-finalmask-normalized.json"
cat >"$masked_input" <<'JSON'
[
  {
    "log": { "loglevel": "warning" },
    "inbounds": [],
    "outbounds": [
      {
        "tag": "proxy-0",
        "protocol": "hysteria",
        "settings": { "version": 2, "address": "l63.example.com", "port": 25565 },
        "streamSettings": {
          "network": "hysteria",
          "hysteriaSettings": { "version": 2, "auth": "secret" },
          "security": "tls",
          "tlsSettings": {
            "serverName": "itx-server.digital",
            "alpn": [ "h3" ],
            "fingerprint": "firefox"
          },
          "finalmask": {
            "udp": [
              { "type": "salamander", "settings": { "password": "salamander-itx-2096" } }
            ]
          }
        }
      }
    ]
  }
]
JSON
normalize "$masked_input" "$masked_output"

if ! grep -Fq '"type": "hysteria2"' "$masked_output"; then
  cat "$masked_output" >&2
  fail "Xray hysteria v2 must normalize to a sing-box hysteria2 outbound"
fi
if ! grep -Fq '"obfs": { "type": "salamander", "password": "salamander-itx-2096" }' "$masked_output"; then
  cat "$masked_output" >&2
  fail "finalmask salamander must become the hysteria2 obfs"
fi

# Control: without finalmask no obfs may appear, otherwise the assertion above
# would pass no matter what the parser does.
plain_input="$WORK_DIR/xray-hy2-plain.json"
plain_output="$WORK_DIR/xray-hy2-plain-normalized.json"
cat >"$plain_input" <<'JSON'
[
  {
    "inbounds": [],
    "outbounds": [
      {
        "tag": "proxy-1",
        "protocol": "hysteria",
        "settings": { "version": 2, "address": "l64.example.com", "port": 25565 },
        "streamSettings": {
          "network": "hysteria",
          "hysteriaSettings": { "version": 2, "auth": "secret" },
          "security": "tls",
          "tlsSettings": { "serverName": "itx-server.digital", "alpn": [ "h3" ] }
        }
      }
    ]
  }
]
JSON
normalize "$plain_input" "$plain_output"

if ! grep -Fq '"type": "hysteria2"' "$plain_output"; then
  cat "$plain_output" >&2
  fail "control fixture must still produce a hysteria2 outbound"
fi
if grep -Fq '"obfs"' "$plain_output"; then
  cat "$plain_output" >&2
  fail "hysteria2 without finalmask must not grow an obfs"
fi

printf 'subscription Xray finalmask checks passed\n'
