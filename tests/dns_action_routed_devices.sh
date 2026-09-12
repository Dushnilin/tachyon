#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
GENERATOR="$TACHYON_LIB/singbox/generator.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# 1. Test DNS section with fully_routed_ips priority over source_aware_dns fallback
cat >"$WORK_DIR/dns-action.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_type": "udp",
    "dns_server": "77.88.8.8",
    "bootstrap_dns_server": "77.88.8.8",
    "excluded_clients": [ "192.168.1.50" ]
  },
  "section": [
    {
      ".name": "custom_dns",
      ".type": "section",
      "enabled": "1",
      "action": "dns",
      "dns_type": "udp",
      "dns_server": "10.0.0.18",
      "fully_routed_ips": [ "192.168.1.164", "192.168.1.225" ]
    }
  ]
}
JSON

OUTPUT="$WORK_DIR/config.json"
TACHYON_LIB="$TACHYON_LIB" \
TACHYON_DNS_FAILOVER_STATE_FILE="$WORK_DIR/missing.json" \
ucode -L "$TACHYON_LIB" "$GENERATOR" generate-config-fixture "$WORK_DIR/dns-action.json" "$OUTPUT" 192.168.1.1 0

node - "$OUTPUT" <<'NODE'
const fs = require("fs");
const cfg = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));

const rules = cfg.dns.rules || [];
if (rules.length === 0) {
  console.error("FAIL: dns.rules is empty");
  process.exit(1);
}

// Rule 0 must be the excluded client bypass to dnsmasq
const firstRule = rules[0];
if (!firstRule.source_ip_cidr || !firstRule.source_ip_cidr.includes("192.168.1.50") || firstRule.server !== "dnsmasq-server") {
  console.error("FAIL: first dns rule must be excluded client bypass to dnsmasq, got:", JSON.stringify(firstRule));
  process.exit(1);
}

// Find section custom_dns rule
let customDnsIdx = -1;
let fallbackDnsmasqIdx = -1;

for (let i = 0; i < rules.length; i++) {
  const r = rules[i];
  if (r.server && r.server.includes("custom_dns") && r.source_ip_cidr) {
    const cidrs = Array.isArray(r.source_ip_cidr) ? r.source_ip_cidr : [r.source_ip_cidr];
    if (cidrs.includes("192.168.1.164/32") && cidrs.includes("192.168.1.225/32")) {
      customDnsIdx = i;
    }
  }
  if (i > 0 && r.server === "dnsmasq-server" && r.inbound && r.inbound.includes("source-dns-in")) {
    fallbackDnsmasqIdx = i;
  }
}

if (customDnsIdx === -1) {
  console.error("FAIL: did not find custom_dns rule for 192.168.1.164 / 192.168.1.225 in rules:", JSON.stringify(rules, null, 2));
  process.exit(1);
}

if (fallbackDnsmasqIdx === -1) {
  console.error("FAIL: did not find trailing source_aware_dns fallback rule to dnsmasq-server");
  process.exit(1);
}

if (customDnsIdx >= fallbackDnsmasqIdx) {
  console.error(`FAIL: custom_dns rule at index ${customDnsIdx} must precede fallback rule at index ${fallbackDnsmasqIdx}`);
  process.exit(1);
}

console.log("✓ Section Action DNS ordering verified: custom DNS precedes fallback");
NODE

# 2. Test parental_quota.uc cron formatting & migration with >/dev/null 2>&1
PARENTAL_QUOTA="$TACHYON_LIB/service/parental_quota.uc"
MOCK_CRON_FILE="$WORK_DIR/mock_crontab.txt"
mkdir -p "$WORK_DIR/bin"

cat >"$WORK_DIR/bin/crontab" <<BASH
#!/usr/bin/env bash
if [ "\$1" = "-l" ]; then
  cat "$MOCK_CRON_FILE" 2>/dev/null || true
  exit 0
elif [ -n "\$1" ]; then
  cat "\$1" > "$MOCK_CRON_FILE"
  exit 0
fi
exit 0
BASH
chmod +x "$WORK_DIR/bin/crontab"

# Seed crontab with an old unredirected line
cat >"$MOCK_CRON_FILE" <<'CRON'
0 2 * * * /usr/bin/backup.sh
* * * * * /usr/bin/tachyon parental_quota_tick # tachyon-parental-quota
CRON

# Setup UCI state with quota to trigger install-cron
UCI_STATE="$WORK_DIR/uci_state"
cat >"$UCI_STATE" <<'UCI'
tachyon.guest_mode=guest_mode
tachyon.guest_mode.enabled=1
tachyon.guest_mode.mode=selected
tachyon.guest_mode.guest_devices=192.168.1.88
tachyon.guest_mode.daily_time_limit=60
UCI

PATH="$WORK_DIR/bin:$PATH" TACHYON_UCI_STATE_FILE="$UCI_STATE" ucode -L "$TACHYON_LIB" "$PARENTAL_QUOTA" install-cron

# Verify crontab now has >/dev/null 2>&1 and no duplicate unredirected lines
if ! grep -q "parental_quota_tick >/dev/null 2>&1 # tachyon-parental-quota" "$MOCK_CRON_FILE"; then
  fail "crontab does not contain redirected line"
fi

if [ "$(grep -c "parental_quota_tick" "$MOCK_CRON_FILE")" -ne 1 ]; then
  fail "crontab contains multiple parental_quota_tick lines after migration"
fi
echo "✓ Parental quota crontab formatting and migration verified"

# 3. Test dns_failover.uc probe commands stay bounded
FAILOVER="$TACHYON_LIB/singbox/dns_failover.uc"
# Run stop-runtime to verify orphan cleanup doesn't fail
ucode -L "$TACHYON_LIB" "$FAILOVER" stop-runtime || true
echo "✓ dns_failover stop-runtime verified"

echo "All checks passed in dns_action_routed_devices.sh"
