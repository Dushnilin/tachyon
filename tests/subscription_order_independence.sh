#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

PARSER_UC="$ROOT_DIR/tachyon/files/usr/lib/subscription/parser.uc"
CACHE_UC="$ROOT_DIR/tachyon/files/usr/lib/subscription/cache.uc"

# 1. Verify that identical subscriptions with reordered outbounds match
cat << 'EOF' > "$WORK_DIR/order_a.json"
{
  "outbounds": [
    {
      "tag": "nl-ams-01",
      "type": "vless",
      "server": "ams.example.com",
      "server_port": 443,
      "uuid": "00000000-0000-0000-0000-000000000001",
      "tls": { "enabled": true, "server_name": "ams.example.com" }
    },
    {
      "tag": "de-fra-02",
      "type": "vless",
      "server": "fra.example.com",
      "server_port": 443,
      "uuid": "00000000-0000-0000-0000-000000000002",
      "tls": { "enabled": true, "server_name": "fra.example.com" }
    },
    {
      "tag": "us-nyc-03",
      "type": "vless",
      "server": "nyc.example.com",
      "server_port": 443,
      "uuid": "00000000-0000-0000-0000-000000000003",
      "tls": { "enabled": true, "server_name": "nyc.example.com" }
    }
  ]
}
EOF

cat << 'EOF' > "$WORK_DIR/order_b.json"
{
  "outbounds": [
    {
      "tag": "us-nyc-03",
      "type": "vless",
      "server": "nyc.example.com",
      "server_port": 443,
      "uuid": "00000000-0000-0000-0000-000000000003",
      "tls": { "enabled": true, "server_name": "nyc.example.com" }
    },
    {
      "tag": "nl-ams-01",
      "type": "vless",
      "server": "ams.example.com",
      "server_port": 443,
      "uuid": "00000000-0000-0000-0000-000000000001",
      "tls": { "enabled": true, "server_name": "ams.example.com" }
    },
    {
      "tag": "de-fra-02",
      "type": "vless",
      "server": "fra.example.com",
      "server_port": 443,
      "uuid": "00000000-0000-0000-0000-000000000002",
      "tls": { "enabled": true, "server_name": "fra.example.com" }
    }
  ]
}
EOF

ucode -L "$TACHYON_LIB" "$PARSER_UC" runtime-outbounds-equal "$WORK_DIR/order_a.json" "$WORK_DIR/order_b.json" ||
  fail "Reordered subscriptions must be considered runtime equal"

# 2. Verify that non-runtime metadata difference (share_link) does not affect equality
cat << 'EOF' > "$WORK_DIR/order_metadata.json"
{
  "outbounds": [
    {
      "tag": "de-fra-02",
      "type": "vless",
      "server": "fra.example.com",
      "server_port": 443,
      "uuid": "00000000-0000-0000-0000-000000000002",
      "tls": { "enabled": true, "server_name": "fra.example.com" },
      "share_link": "vless://00000000-0000-0000-0000-000000000002@fra.example.com:443#fra"
    },
    {
      "tag": "nl-ams-01",
      "type": "vless",
      "server": "ams.example.com",
      "server_port": 443,
      "uuid": "00000000-0000-0000-0000-000000000001",
      "tls": { "enabled": true, "server_name": "ams.example.com" }
    },
    {
      "tag": "us-nyc-03",
      "type": "vless",
      "server": "nyc.example.com",
      "server_port": 443,
      "uuid": "00000000-0000-0000-0000-000000000003",
      "tls": { "enabled": true, "server_name": "nyc.example.com" }
    }
  ]
}
EOF

ucode -L "$TACHYON_LIB" "$PARSER_UC" runtime-outbounds-equal "$WORK_DIR/order_a.json" "$WORK_DIR/order_metadata.json" ||
  fail "Subscriptions differing only by share_link metadata and order must be considered equal"

# 3. Verify that real configuration change is NOT equal
cat << 'EOF' > "$WORK_DIR/order_different.json"
{
  "outbounds": [
    {
      "tag": "nl-ams-01",
      "type": "vless",
      "server": "ams.example.com",
      "server_port": 8443,
      "uuid": "00000000-0000-0000-0000-000000000001",
      "tls": { "enabled": true, "server_name": "ams.example.com" }
    },
    {
      "tag": "de-fra-02",
      "type": "vless",
      "server": "fra.example.com",
      "server_port": 443,
      "uuid": "00000000-0000-0000-0000-000000000002",
      "tls": { "enabled": true, "server_name": "fra.example.com" }
    },
    {
      "tag": "us-nyc-03",
      "type": "vless",
      "server": "nyc.example.com",
      "server_port": 443,
      "uuid": "00000000-0000-0000-0000-000000000003",
      "tls": { "enabled": true, "server_name": "nyc.example.com" }
    }
  ]
}
EOF

if ucode -L "$TACHYON_LIB" "$PARSER_UC" runtime-outbounds-equal "$WORK_DIR/order_a.json" "$WORK_DIR/order_different.json"; then
  fail "Subscriptions with port change must not be considered runtime equal"
fi

# 4. Verify that missing an outbound is NOT equal
cat << 'EOF' > "$WORK_DIR/order_missing.json"
{
  "outbounds": [
    {
      "tag": "nl-ams-01",
      "type": "vless",
      "server": "ams.example.com",
      "server_port": 443,
      "uuid": "00000000-0000-0000-0000-000000000001",
      "tls": { "enabled": true, "server_name": "ams.example.com" }
    }
  ]
}
EOF

if ucode -L "$TACHYON_LIB" "$PARSER_UC" runtime-outbounds-equal "$WORK_DIR/order_a.json" "$WORK_DIR/order_missing.json"; then
  fail "Subscriptions with missing outbounds must not be considered runtime equal"
fi

echo "subscription_order_independence: ALL ASSERTIONS PASSED"
