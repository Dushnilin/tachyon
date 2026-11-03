#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

set -eo pipefail

ucode() {
  command ucode -L "$TACHYON_LIB" "$@"
}

PARSER="$ROOT_DIR/tachyon/files/usr/lib/subscription/parser.uc"

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

# Flat Xray VLESS settings (`settings.address` / `port` / `id` / `flow` without `vnext`)
flat_vless_input="$WORK_DIR/xray-flat-vless.json"
flat_vless_output="$WORK_DIR/xray-flat-vless-normalized.json"
cat >"$flat_vless_input" <<'JSON'
[
  {
    "remarks": "🇷🇺 Россия · XHTTP",
    "inbounds": [],
    "outbounds": [
      {
        "tag": "proxy",
        "protocol": "vless",
        "settings": {
          "address": "arseniy.online",
          "port": 8443,
          "id": "e3e1a852-b8ed-bc84-a451-577ba0a45ec1",
          "encryption": "none",
          "flow": "xtls-rprx-vision"
        },
        "streamSettings": {
          "network": "xhttp",
          "security": "reality",
          "realitySettings": {
            "serverName": "api-maps.yandex.ru",
            "publicKey": "E99v69e07uX9dY8v116750k9044m3x8037B9s5647F8",
            "shortId": "9ef12456efbd135a",
            "fingerprint": "firefox"
          },
          "xhttpSettings": {
            "host": "api-maps.yandex.ru",
            "path": "/xh-path",
            "mode": "auto"
          }
        }
      }
    ]
  }
]
JSON
normalize "$flat_vless_input" "$flat_vless_output"

if ! grep -Fq '"type": "vless"' "$flat_vless_output"; then
  cat "$flat_vless_output" >&2
  fail "Xray flat VLESS settings must normalize to a sing-box vless outbound"
fi
if ! grep -Fq '"flow": "xtls-rprx-vision"' "$flat_vless_output"; then
  cat "$flat_vless_output" >&2
  fail "Xray flat VLESS settings must preserve settings.flow"
fi
if ! grep -Fq '"tag": "🇷🇺 Россия · XHTTP"' "$flat_vless_output"; then
  cat "$flat_vless_output" >&2
  fail "Xray flat VLESS settings must use remarks as tag when outbound tag is generic"
fi

printf 'subscription Xray finalmask checks passed\n'
