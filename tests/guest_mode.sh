#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

NFT_RUNTIME="$ROOT_DIR/tachyon/files/usr/lib/nft/apply.uc"
VALIDATOR_RUNTIME="$ROOT_DIR/tachyon/files/usr/lib/config/validator.uc"
PARENTAL_QUOTA="$ROOT_DIR/tachyon/files/usr/lib/service/parental_quota.uc"
NFT_LOG="$WORK_DIR/nft.log"

nft_ucode() {
  ucode -L "$TACHYON_LIB" "$NFT_RUNTIME" "$@"
}

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

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  local label="$3"

  if grep -Fq "$unexpected" "$file"; then
    fail "$label: unexpected '$unexpected' found"
  fi
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

# ─── 1. Selected Mode Test ───────────────────────────────────────────────────
cat >"$WORK_DIR/guest_selected.json" <<'JSON'
{
  "guest_mode": [
    {
      ".name": "guest_mode",
      "enabled": "1",
      "mode": "selected",
      "guest_devices": [ "192.168.1.150", "aa:bb:cc:dd:ee:ff" ],
      "isolate_lan": "1",
      "block_router_admin": "1",
      "start_time": "08:00",
      "end_time": "22:00",
      "days": [ "mon", "tue", "wed", "thu", "fri" ]
    }
  ]
}
JSON

rm -f "$NFT_LOG"
nft_ucode nft-add-guest-mode-rules-fixture "$WORK_DIR/guest_selected.json" "tachyon" "tachyon_ifaces" "localv4" "localv6"

# Router admin drop in guest_input
assert_contains "$NFT_LOG" "guest_input	ether	saddr	@tachyon_guest_mac	counter	drop	comment	\"tachyon-guest-admin-drop\"" "selected mac admin drop"
assert_contains "$NFT_LOG" "guest_input	ip	saddr	@tachyon_guest_ip	counter	drop	comment	\"tachyon-guest-admin-drop\"" "selected ip admin drop"

# Essential services allowed in guest_input
assert_contains "$NFT_LOG" "guest_input	udp	dport	{ 67, 68 }	accept" "DHCP accepted"
assert_contains "$NFT_LOG" "guest_input	udp	dport	53	accept" "DNS UDP accepted"
assert_contains "$NFT_LOG" "guest_input	tcp	dport	53	accept" "DNS TCP accepted"
assert_contains "$NFT_LOG" "guest_input	icmp	type	echo-request	accept" "ICMP echo accepted"

# LAN isolation in guest_forward
assert_contains "$NFT_LOG" "guest_forward	ether	saddr	@tachyon_guest_mac	ip	daddr	@localv4	counter	drop	comment	\"tachyon-guest-lan-drop\"" "mac lan drop"
assert_contains "$NFT_LOG" "guest_forward	ip	saddr	@tachyon_guest_ip	ip	daddr	@localv4	counter	drop	comment	\"tachyon-guest-lan-drop\"" "ip lan drop"

# Byte accounting counters
assert_contains "$NFT_LOG" "guest_forward	ether	saddr	aa:bb:cc:dd:ee:ff	counter	comment	\"tachyon-guest-byte:aa:bb:cc:dd:ee:ff\"" "mac byte counter"
assert_contains "$NFT_LOG" "guest_forward	ip	saddr	192.168.1.150	counter	comment	\"tachyon-guest-byte:192.168.1.150\"" "ip byte counter"

# Schedule restriction drops only guest devices outside window
assert_contains "$NFT_LOG" "guest_forward	ether	saddr	@tachyon_guest_mac	counter	drop	comment	\"guest-time-window-closed\"" "mac time window drop"
assert_contains "$NFT_LOG" "guest_forward	ip	saddr	@tachyon_guest_ip	counter	drop	comment	\"guest-time-window-closed\"" "ip time window drop"

# ─── 2. Inverted Mode Test ───────────────────────────────────────────────────
cat >"$WORK_DIR/guest_inverted.json" <<'JSON'
{
  "guest_mode": [
    {
      ".name": "guest_mode",
      "enabled": "1",
      "mode": "inverted",
      "trusted_devices": [ "192.168.1.10", "11:22:33:44:55:66" ],
      "isolate_lan": "1",
      "block_router_admin": "1",
      "start_time": "09:00",
      "end_time": "21:00"
    }
  ]
}
JSON

rm -f "$NFT_LOG"
nft_ucode nft-add-guest-mode-rules-fixture "$WORK_DIR/guest_inverted.json" "tachyon" "tachyon_ifaces" "localv4" "localv6"

# Trusted devices return early
assert_contains "$NFT_LOG" "guest_input	ether	saddr	@tachyon_trusted_mac	return" "trusted mac returns in input"
assert_contains "$NFT_LOG" "guest_input	ip	saddr	@tachyon_trusted_ip	return" "trusted ip returns in input"
assert_contains "$NFT_LOG" "guest_forward	ether	saddr	@tachyon_trusted_mac	return" "trusted mac returns in forward"
assert_contains "$NFT_LOG" "guest_forward	ip	saddr	@tachyon_trusted_ip	return" "trusted ip returns in forward"

# All non-trusted devices dropped
assert_contains "$NFT_LOG" "guest_input	iifname	@tachyon_ifaces	counter	drop	comment	\"tachyon-guest-admin-drop\"" "inverted admin drop"
assert_contains "$NFT_LOG" "guest_forward	iifname	@tachyon_ifaces	ip	daddr	@localv4	counter	drop	comment	\"tachyon-guest-lan-drop\"" "inverted lan drop"
assert_contains "$NFT_LOG" "guest_forward	iifname	@tachyon_ifaces	counter	comment	\"tachyon-guest-traffic\"" "inverted traffic counter"
assert_contains "$NFT_LOG" "guest_forward	iifname	@tachyon_ifaces	counter	drop	comment	\"guest-time-window-closed\"" "inverted time window drop"

# ─── 3. Validator Tests ──────────────────────────────────────────────────────
cat >"$WORK_DIR/valid_config.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"] },
  "guest_mode": [
    {
      ".name": "guest_mode",
      "enabled": "1",
      "mode": "selected",
      "guest_devices": [ "192.168.1.50", "aa:bb:cc:dd:ee:ff" ],
      "daily_time_limit": "120",
      "daily_traffic_limit": "1024",
      "start_time": "08:00",
      "end_time": "20:00"
    }
  ]
}
JSON

if ! ucode -L "$TACHYON_LIB" "$VALIDATOR_RUNTIME" validate-runtime-fixture "$WORK_DIR/valid_config.json" "{}" >/dev/null 2>&1; then
  fail "Validator should accept valid guest_mode config"
fi

cat >"$WORK_DIR/invalid_mode.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"] },
  "guest_mode": [
    {
      ".name": "guest_mode",
      "enabled": "1",
      "mode": "invalid_mode_name"
    }
  ]
}
JSON

if ucode -L "$TACHYON_LIB" "$VALIDATOR_RUNTIME" validate-runtime-fixture "$WORK_DIR/invalid_mode.json" "{}" >/dev/null 2>&1; then
  fail "Validator must reject invalid guest mode"
fi

cat >"$WORK_DIR/invalid_device.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"] },
  "guest_mode": [
    {
      ".name": "guest_mode",
      "enabled": "1",
      "mode": "selected",
      "guest_devices": [ "not-an-ip-or-mac" ]
    }
  ]
}
JSON

if ucode -L "$TACHYON_LIB" "$VALIDATOR_RUNTIME" validate-runtime-fixture "$WORK_DIR/invalid_device.json" "{}" >/dev/null 2>&1; then
  fail "Validator must reject invalid guest device format"
fi

cat >"$WORK_DIR/invalid_quota.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"] },
  "guest_mode": [
    {
      ".name": "guest_mode",
      "enabled": "1",
      "daily_time_limit": "99999"
    }
  ]
}
JSON

if ucode -L "$TACHYON_LIB" "$VALIDATOR_RUNTIME" validate-runtime-fixture "$WORK_DIR/invalid_quota.json" "{}" >/dev/null 2>&1; then
  fail "Validator must reject out-of-range daily_time_limit"
fi

# ─── 4. Parental Quota Daemon Guest Integration ──────────────────────────────
STATE_FILE="$WORK_DIR/quotas.json"
UCI_STATE="$WORK_DIR/uci_state"

cat >"$UCI_STATE" <<'EOF'
tachyon.guest_mode=guest_mode
tachyon.guest_mode.enabled=1
tachyon.guest_mode.mode=selected
tachyon.guest_mode.guest_devices=192.168.1.88 aa:bb:cc:dd:ee:ff
tachyon.guest_mode.daily_time_limit=60
tachyon.guest_mode.daily_traffic_limit=500
tachyon.guest_mode.notify=0
EOF

# Prepopulate state file with 59 minutes (1 minute below limit)
cat >"$STATE_FILE" <<'EOF'
{"day":"2026-09-08","devices":{},"guest_devices":{"192.168.1.88":{"minutes":59,"bytes":0,"blocked":false}}}
EOF

# Mock `date`, `ip`, `logger`
cat >"$WORK_DIR/bin/date" <<'EOF'
#!/usr/bin/env bash
echo "2026-09-08"
EOF
chmod +x "$WORK_DIR/bin/date"

cat >"$WORK_DIR/bin/logger" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$WORK_DIR/bin/logger"

cat >"$WORK_DIR/bin/ip" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "neigh" ] && [ "$2" = "show" ]; then
  echo "192.168.1.88 dev br-lan lladdr aa:bb:cc:dd:ee:ff REACHABLE"
fi
exit 0
EOF
chmod +x "$WORK_DIR/bin/ip"

# Run tick with TACHYON_UCI_STATE_FILE
PARENTAL_QUOTA_STATE_FILE="$STATE_FILE" TACHYON_UCI_STATE_FILE="$UCI_STATE" ucode -L "$TACHYON_LIB" "$PARENTAL_QUOTA" tick

# Device should now have reached 60 minutes and be marked blocked
grep -Eq '"blocked":\s*true' "$STATE_FILE" || fail "Guest device should be blocked after reaching time limit"

# Test status command
STATUS_JSON="$(PARENTAL_QUOTA_STATE_FILE="$STATE_FILE" TACHYON_UCI_STATE_FILE="$UCI_STATE" ucode -L "$TACHYON_LIB" "$PARENTAL_QUOTA" status)"
echo "$STATUS_JSON" | grep -q '"guest_mode"' || fail "Status must contain guest_mode object"
echo "$STATUS_JSON" | grep -Eq '"time_limit":\s*60' || fail "Status must contain time_limit:60"
echo "$STATUS_JSON" | grep -Eq '"traffic_limit":\s*500' || fail "Status must contain traffic_limit:500"

printf 'All guest mode isolation, validation, and quota tests passed successfully\n'
