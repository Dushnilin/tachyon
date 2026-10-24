#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

TACHYON_LIB="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"
if [ ! -d "$TACHYON_LIB" ]; then
  TACHYON_LIB="/usr/lib/tachyon"
fi

fixture() {
  cat >"$WORK_DIR/fixture.json" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "source_network_interfaces": "br-lan",
    "excluded_ips": [ "192.168.1.50" ]
  },
  "server": [
    {
      ".name": "home_node",
      ".type": "server",
      "enabled": "1",
      "protocol": "hysteria2",
      "listen_port": "8443",
      "server_password": "secretpassword",
      "routing_mode": "rules"
    }
  ],
  "section": [
    {
      ".name": "youtube_zapret",
      ".type": "section",
      "enabled": "1",
      "action": "zapret",
      "domain": ["youtube.com", "googlevideo.com"]
    },
    {
      ".name": "instagram_proxy",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "ip_cidr": ["157.240.0.0/16"]
    }
  ]
}
JSON
}

generate() {
  mkdir -p "$WORK_DIR/out.section-cache"
  ucode -L "$TACHYON_LIB" "$TACHYON_LIB/tachyon_core/generator.uc" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$WORK_DIR/singbox.json" "127.0.0.1" 0 0
}

fixture
generate

CONFIG="$WORK_DIR/singbox.json"

# 1. Verify hijack-dns rules exist for server-home_node-in on port 53 and protocol dns
node -e '
const fs = require("fs");
const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const rules = (cfg.route && cfg.route.rules) || [];

const hijackDnsPort = rules.find(r => r.action === "hijack-dns" && r.inbound === "server-home_node-in" && r.port === 53);
if (!hijackDnsPort) {
  console.error("Missing hijack-dns port 53 rule for server-home_node-in");
  process.exit(1);
}

const hijackDnsProto = rules.find(r => r.action === "hijack-dns" && r.inbound === "server-home_node-in" && r.protocol === "dns");
if (!hijackDnsProto) {
  console.error("Missing hijack-dns protocol dns rule for server-home_node-in");
  process.exit(1);
}

const loRuleIdx = rules.findIndex(r => r.action === "route" && r.inbound === "server-home_node-in" && Array.isArray(r.ip_cidr) && r.ip_cidr.includes("127.0.0.0/8") && r.outbound === "lo-direct-out");
const lanRuleIdx = rules.findIndex(r => r.action === "route" && r.inbound === "server-home_node-in" && Array.isArray(r.ip_cidr) && r.ip_cidr.includes("192.168.1.0/24") && r.outbound === "lan-direct-out");
const privRuleIdx = rules.findIndex(r => r.action === "route" && r.inbound === "server-home_node-in" && r.ip_is_private === true && r.outbound === "direct-out");
if (loRuleIdx < 0 || lanRuleIdx < 0 || privRuleIdx < 0 || !(loRuleIdx < lanRuleIdx && lanRuleIdx < privRuleIdx)) {
  console.error("Expected lo-direct-out -> lan-direct-out -> direct-out (ip_is_private) route order for server-home_node-in");
  process.exit(1);
}

// Check that sniff rule includes server-home_node-in
const sniffRule = rules.find(r => r.action === "sniff" && (r.inbound === "server-home_node-in" || (Array.isArray(r.inbound) && r.inbound.includes("server-home_node-in"))));
if (!sniffRule) {
  console.error("Missing sniff rule covering server-home_node-in");
  process.exit(1);
}

// Check that action: resolve is cloned for server-home_node-in
const resolveRule = rules.find(r => r.action === "resolve" && r.inbound === "server-home_node-in" && r.domain && r.domain.includes("youtube.com"));
if (!resolveRule) {
  console.error("Missing action: resolve rule cloned for server-home_node-in and youtube.com");
  process.exit(1);
}

// Check that route rule for youtube is cloned for server-home_node-in
const youtubeRoute = rules.find(r => r.action === "route" && r.inbound === "server-home_node-in" && r.domain && r.domain.includes("youtube.com"));
if (!youtubeRoute) {
  console.error("Missing action: route rule cloned for server-home_node-in and youtube.com");
  process.exit(1);
}

// Check that IP CIDR rule for instagram is cloned for server-home_node-in
const instaRoute = rules.find(r => r.action === "route" && r.inbound === "server-home_node-in" && r.ip_cidr && r.ip_cidr.includes("157.240.0.0/16"));
if (!instaRoute) {
  console.error("Missing IP CIDR rule cloned for server-home_node-in and Instagram subnet");
  process.exit(1);
}

// Check that excluded_ips bypass rule is scoped to tproxy-in/tproxy6-in and never hijacks server inbounds
const excludedRule = rules.find(r => r.action === "route" && r.outbound === "bypass-out" && (r.source_ip_cidr === "192.168.1.50/32" || (Array.isArray(r.source_ip_cidr) && r.source_ip_cidr.includes("192.168.1.50/32"))));
if (!excludedRule || !Array.isArray(excludedRule.inbound) || !excludedRule.inbound.includes("tproxy-in") || excludedRule.inbound.includes("server-home_node-in")) {
  console.error("excluded_ips rule must be scoped to tproxy-in/tproxy6-in:", JSON.stringify(excludedRule));
  process.exit(1);
}

console.log("All server inbound DNS & routing assertions passed successfully!");
' "$CONFIG" || fail "server inbound verification failed"

printf 'PASS: server inbound DNS and routing tests passed\n'
