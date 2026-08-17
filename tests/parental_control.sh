#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
NFT_RUNTIME="$ROOT_DIR/tachyon/files/usr/lib/nft/apply.uc"
VALIDATOR_RUNTIME="$ROOT_DIR/tachyon/files/usr/lib/config/validator.uc"
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

cat >"$WORK_DIR/schedule_fixture.json" <<'JSON'
{
  "section": [
    {
      ".name": "sec_youtube",
      "enabled": "1",
      "action": "connection",
      "ip_cidr": [ "142.250.0.0/15" ]
    },
    {
      ".name": "sec_discord",
      "enabled": "1",
      "action": "connection",
      "ip_cidr": [ "162.158.0.0/16" ]
    }
  ],
  "schedule": [
    {
      ".name": "phone_night",
      "enabled": "1",
      "device_ip": "192.168.1.150",
      "target": "all",
      "action": "block",
      "start_time": "22:00",
      "end_time": "08:00",
      "days": [ "mon", "tue", "wed", "thu", "fri" ]
    },
    {
      ".name": "tv_multi",
      "enabled": "1",
      "device_ip": "192.168.1.160",
      "target": "sections",
      "sections": [ "sec_youtube", "sec_discord" ],
      "action": "block",
      "start_time": "21:00",
      "end_time": "07:00",
      "days": [ "sat", "sun" ]
    }
  ]
}
JSON

# Run nft-add-schedule-rules-fixture
nft_ucode nft-add-schedule-rules-fixture "$WORK_DIR/schedule_fixture.json" "tachyon"

# Verify rules in NFT_LOG
assert_contains "$NFT_LOG" "parental_forward	ip	saddr	192.168.1.150	meta	day	{ Friday, Monday, Thursday, Tuesday, Wednesday }	meta	hour	\"22:00:00\"-\"23:59:59\"	counter	drop" "midnight wrap part 1"
assert_contains "$NFT_LOG" "parental_forward	ip	saddr	192.168.1.150	meta	day	{ Friday, Monday, Thursday, Tuesday, Wednesday }	meta	hour	\"00:00:00\"-\"08:00:00\"	counter	drop" "midnight wrap part 2"
assert_contains "$NFT_LOG" "parental_control	ip	saddr	192.168.1.150	meta	day	{ Friday, Monday, Thursday, Tuesday, Wednesday }	meta	hour	\"22:00:00\"-\"23:59:59\"	counter	drop" "parental_control drop"

# Verify per-section blocking
assert_contains "$NFT_LOG" "ip	saddr	192.168.1.160	meta	day	{ Saturday, Sunday }	meta	hour	\"21:00:00\"-\"23:59:59\"	ip	daddr	@tachyon_rule_sec_youtube_subnets	counter	drop" "section youtube subnet drop"
assert_contains "$NFT_LOG" "ip	saddr	192.168.1.160	meta	day	{ Saturday, Sunday }	meta	hour	\"21:00:00\"-\"23:59:59\"	ip	daddr	@tachyon_rule_sec_discord_subnets	counter	drop" "section discord subnet drop"

# Verify signature changes when schedule is modified
SIG1="$(nft_ucode nft-runtime-signature-fixture "$WORK_DIR/schedule_fixture.json")"

cat >"$WORK_DIR/schedule_fixture2.json" <<'JSON'
{
  "section": [
    {
      ".name": "sec_youtube",
      "enabled": "1",
      "action": "connection"
    }
  ],
  "schedule": [
    {
      ".name": "phone_night",
      "enabled": "0",
      "device_ip": "192.168.1.150",
      "target": "all"
    }
  ]
}
JSON

SIG2="$(nft_ucode nft-runtime-signature-fixture "$WORK_DIR/schedule_fixture2.json")"

[ "$SIG1" != "$SIG2" ] || fail "Signature must change when schedule is updated"

# Verify validator rejects invalid schedule time
cat >"$WORK_DIR/invalid_time.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"] },
  "schedule": [
    {
      ".name": "bad_time",
      "enabled": "1",
      "device_ip": "192.168.1.100",
      "start_time": "25:00"
    }
  ]
}
JSON

if ucode -L "$TACHYON_LIB" "$VALIDATOR_RUNTIME" validate-runtime-fixture "$WORK_DIR/invalid_time.json" "{}" >/dev/null 2>&1; then
  fail "Validator must reject invalid start_time 25:00"
fi

# Verify validator rejects invalid schedule device IP
cat >"$WORK_DIR/invalid_ip.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"] },
  "schedule": [
    {
      ".name": "bad_ip",
      "enabled": "1",
      "device_ip": "999.999.999.999",
      "start_time": "22:00",
      "end_time": "08:00"
    }
  ]
}
JSON

if ucode -L "$TACHYON_LIB" "$VALIDATOR_RUNTIME" validate-runtime-fixture "$WORK_DIR/invalid_ip.json" "{}" >/dev/null 2>&1; then
  fail "Validator must reject invalid device_ip 999.999.999.999"
fi

# Verify validator rejects unknown target section
cat >"$WORK_DIR/invalid_target.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"] },
  "schedule": [
    {
      ".name": "bad_target",
      "enabled": "1",
      "device_ip": "192.168.1.100",
      "target": "non_existent_section"
    }
  ]
}
JSON

if ucode -L "$TACHYON_LIB" "$VALIDATOR_RUNTIME" validate-runtime-fixture "$WORK_DIR/invalid_target.json" "{}" >/dev/null 2>&1; then
  fail "Validator must reject non-existent target section"
fi

printf 'Parental control and schedule tests passed\n'
