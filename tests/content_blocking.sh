#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
GENERATOR_UC="$TACHYON_LIB/singbox/generator.uc"
NFT_RUNTIME="$TACHYON_LIB/nft/apply.uc"
VALIDATOR_RUNTIME="$TACHYON_LIB/config/validator.uc"
WORK_DIR="$(mktemp -d)"
NFT_LOG="$WORK_DIR/nft.log"

nft_ucode() {
  ucode -L "$TACHYON_LIB" "$NFT_RUNTIME" "$@"
}

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  cat "$NFT_LOG" >&2 2>/dev/null || true
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  local label="$3"

  grep -Fq "$expected" "$file" || fail "$label: expected '$expected'"
}

generate_config() {
  local fixture="$1"
  local output="$2"

  mkdir -p "$output.section-cache" "$output.rulesets"
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
    "$fixture" "$output" "127.0.0.1" "0"
}

# ─── Fixture: always-on block with IP device ─────────────────────────────────
cat >"$WORK_DIR/fixture_always_on.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_path": "/tmp/sing-box/config.json",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "sec_proxy",
      "enabled": "1",
      "action": "connection",
      "label": "Main proxy",
      "selector_proxy_links": [ "socks5://127.0.0.1:1080#Proxy" ]
    }
  ],
  "schedule": [
    {
      ".name": "kids_youtube",
      "enabled": "1",
      "label": "Kids YouTube",
      "device_ip": [ "192.168.1.150" ],
      "blocked_domains": [ "youtube.com", "googlevideo.com" ],
      "mode": "block",
      "dns_level": "1",
      "notify": "1"
    }
  ]
}
JSON

OUT="$WORK_DIR/always_on.json"
generate_config "$WORK_DIR/fixture_always_on.json" "$OUT"

# dns-block-in inbound must exist
assert_contains "$OUT" '"tag": "dns-block-in"' "always-on: dns-block-in inbound"
assert_contains "$OUT" '"listen_port": 1053' "always-on: block inbound port 1053"

# DNS reject rules with source_ip_cidr for IP devices
grep -o '"source_ip_cidr": \[ [^]]*\]' "$OUT" | grep -q '192.168.1.150/32' ||
  fail "always-on: DNS rule must carry source_ip_cidr 192.168.1.150/32"
assert_contains "$OUT" '"action": "reject"' "always-on: DNS reject action"

# Route rule fallback (always-on schedule, IP device)
grep -o '"action": "reject"' "$OUT" | head -2 >/dev/null ||
  fail "always-on: route reject rule missing"

# ─── Fixture: whitelist (allow only) mode ────────────────────────────────────
cat >"$WORK_DIR/fixture_allow.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_path": "/tmp/sing-box/config.json",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "sec_proxy",
      "enabled": "1",
      "action": "connection",
      "label": "Main proxy",
      "selector_proxy_links": [ "socks5://127.0.0.1:1080#Proxy" ]
    }
  ],
  "schedule": [
    {
      ".name": "kids_whitelist",
      "enabled": "1",
      "label": "Kids Whitelist",
      "device_ip": [ "192.168.1.151" ],
      "blocked_domains": [ "school.edu", "khanacademy.org" ],
      "mode": "allow",
      "dns_level": "1",
      "notify": "0"
    }
  ]
}
JSON

OUT="$WORK_DIR/allow.json"
generate_config "$WORK_DIR/fixture_allow.json" "$OUT"

# Whitelist mode must invert the DNS rule
grep -o '"invert": true' "$OUT" | head -1 >/dev/null ||
  fail "whitelist: DNS rule must be inverted"
assert_contains "$OUT" '"source_ip_cidr": [ "192.168.1.151/32" ]' "whitelist: source_ip_cidr scoped"

# ─── Fixture: MAC-only device (no IP in DNS rules, nft redirect only) ────────
cat >"$WORK_DIR/fixture_mac.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_path": "/tmp/sing-box/config.json",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "sec_proxy",
      "enabled": "1",
      "action": "connection",
      "label": "Main proxy",
      "selector_proxy_links": [ "socks5://127.0.0.1:1080#Proxy" ]
    }
  ],
  "schedule": [
    {
      ".name": "tv_block",
      "enabled": "1",
      "label": "TV Block",
      "device_ip": [ "11:22:33:44:55:66" ],
      "blocked_domains": [ "netflix.com" ],
      "mode": "block",
      "dns_level": "1",
      "notify": "0"
    }
  ]
}
JSON

OUT="$WORK_DIR/mac.json"
generate_config "$WORK_DIR/fixture_mac.json" "$OUT"

# MAC-only device: DNS rules must NOT carry source_ip_cidr (no IP known)
if grep -o '"source_ip_cidr"' "$OUT" | head -1 >/dev/null; then
  fail "mac-only: DNS rule must not carry source_ip_cidr for MAC-only device"
fi
# But dns-block-in must still exist
assert_contains "$OUT" '"tag": "dns-block-in"' "mac-only: dns-block-in inbound"

# ─── nftables DNS redirect rules ─────────────────────────────────────────────
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/nft" <<NFT
#!/usr/bin/env bash
set -eo pipefail
{
  printf 'nft'
  for arg in "\$@"; do
    printf '\t%s' "\$arg"
  done
  printf '\n'
} >>"$NFT_LOG"
exit 0
NFT
chmod +x "$WORK_DIR/bin/nft"
export PATH="$WORK_DIR/bin:$PATH"

cat >"$WORK_DIR/nft_fixture.json" <<'JSON'
{
  "schedule": [
    {
      ".name": "kids_youtube",
      "enabled": "1",
      "label": "Kids YouTube",
      "device_ip": [ "192.168.1.150", "11:22:33:44:55:66" ],
      "blocked_domains": [ "youtube.com" ],
      "start_time": "22:00",
      "end_time": "08:00",
      "mode": "block",
      "dns_level": "1",
      "notify": "1"
    },
    {
      ".name": "tv_always",
      "enabled": "1",
      "label": "TV Always",
      "device_ip": [ "192.168.1.160" ],
      "blocked_domains": [ "netflix.com" ],
      "mode": "block",
      "dns_level": "1",
      "notify": "0"
    }
  ]
}
JSON

nft_ucode nft-add-dns-block-rules-fixture "$WORK_DIR/nft_fixture.json" "tachyon"

# Time-gated rule: IP device, meta hour window, redirect to block target
assert_contains "$NFT_LOG" "dns_block	ip	saddr	192.168.1.150	meta	hour	\"22:00:00\"-\"23:59:59\"	udp	dport	53	redirect	to	127.0.0.43:1053	counter	comment" "time-gated udp redirect"
assert_contains "$NFT_LOG" "dns_block	ip	saddr	192.168.1.150	meta	hour	\"00:00:00\"-\"08:00:00\"	udp	dport	53	redirect	to	127.0.0.43:1053" "midnight wrap udp redirect"
assert_contains "$NFT_LOG" "tcp	dport	53	redirect	to	127.0.0.43:1053" "tcp dns redirect"

# MAC device redirect
assert_contains "$NFT_LOG" "dns_block	ether	saddr	11:22:33:44:55:66	meta	hour" "mac redirect with time"

# Always-on schedule: no meta hour matcher
if grep -Fq "192.168.1.160	meta	hour" "$NFT_LOG"; then
  fail "always-on schedule must not carry meta hour matcher"
fi
assert_contains "$NFT_LOG" "ip	saddr	192.168.1.160	udp	dport	53	redirect	to	127.0.0.43:1053" "always-on redirect"

# ─── Validator: invalid blocked domain rejected ──────────────────────────────
cat >"$WORK_DIR/invalid_domain.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"] },
  "schedule": [
    {
      ".name": "bad_domain",
      "enabled": "1",
      "device_ip": "192.168.1.100",
      "blocked_domains": [ "not a domain!!" ]
    }
  ]
}
JSON

if ucode -L "$TACHYON_LIB" "$VALIDATOR_RUNTIME" validate-runtime-fixture "$WORK_DIR/invalid_domain.json" "{}" >/dev/null 2>&1; then
  fail "Validator must reject invalid blocked_domains"
fi

# ─── Validator: invalid mode rejected ────────────────────────────────────────
cat >"$WORK_DIR/invalid_mode.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"] },
  "schedule": [
    {
      ".name": "bad_mode",
      "enabled": "1",
      "device_ip": "192.168.1.100",
      "blocked_domains": [ "youtube.com" ],
      "mode": "banana"
    }
  ]
}
JSON

if ucode -L "$TACHYON_LIB" "$VALIDATOR_RUNTIME" validate-runtime-fixture "$WORK_DIR/invalid_mode.json" "{}" >/dev/null 2>&1; then
  fail "Validator must reject invalid mode"
fi

# ─── Validator: invalid dns_level rejected ───────────────────────────────────
cat >"$WORK_DIR/invalid_dns_level.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"] },
  "schedule": [
    {
      ".name": "bad_level",
      "enabled": "1",
      "device_ip": "192.168.1.100",
      "blocked_domains": [ "youtube.com" ],
      "dns_level": "5"
    }
  ]
}
JSON

if ucode -L "$TACHYON_LIB" "$VALIDATOR_RUNTIME" validate-runtime-fixture "$WORK_DIR/invalid_dns_level.json" "{}" >/dev/null 2>&1; then
  fail "Validator must reject invalid dns_level"
fi

# ─── Signature changes when blocked_domains change ───────────────────────────
SIG1="$(nft_ucode nft-runtime-signature-fixture "$WORK_DIR/nft_fixture.json")"

cat >"$WORK_DIR/nft_fixture2.json" <<'JSON'
{
  "schedule": [
    {
      ".name": "kids_youtube",
      "enabled": "1",
      "label": "Kids YouTube",
      "device_ip": [ "192.168.1.150" ],
      "blocked_domains": [ "tiktok.com" ],
      "start_time": "22:00",
      "end_time": "08:00",
      "mode": "block",
      "dns_level": "1",
      "notify": "1"
    }
  ]
}
JSON

SIG2="$(nft_ucode nft-runtime-signature-fixture "$WORK_DIR/nft_fixture2.json")"

[ "$SIG1" != "$SIG2" ] || fail "Signature must change when blocked_domains are updated"

printf 'Content blocking checks passed\n'
