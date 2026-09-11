#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$ROOT_DIR/tachyon/files/usr/lib"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

TMP_DIR="$(mktemp -d /tmp/tachyon_community_subnets_test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

DISCORD_LST="$TMP_DIR/community-subnets-discord.lst"
OTHER_LST="$TMP_DIR/community-subnets-other.lst"

cat > "$DISCORD_LST" << 'EOF'
# Discord community subnets
66.22.196.0/22
104.16.0.0/12
172.64.0.0/13
162.158.0.0/15
2606:4700::/32
162.159.128.0/21
EOF

cat > "$OTHER_LST" << 'EOF'
# Other service
104.16.0.0/12
1.2.3.0/24
EOF

# 1. Test core.ip is_cloudflare_shared_cidr
ucode -L "$LIB_DIR" -e '
let core_ip = require("core.ip");
if (!core_ip.is_cloudflare_shared_cidr("104.16.0.0/12")) exit(1);
if (!core_ip.is_cloudflare_shared_cidr("172.64.0.0/13")) exit(2);
if (!core_ip.is_cloudflare_shared_cidr("162.158.0.0/15")) exit(3);
if (!core_ip.is_cloudflare_shared_cidr("2606:4700::/32")) exit(4);
if (core_ip.is_cloudflare_shared_cidr("66.22.196.0/22")) exit(5);
if (core_ip.is_cloudflare_shared_cidr("162.159.128.0/21")) exit(6);
if (core_ip.is_cloudflare_shared_cidr("1.1.1.1/32")) exit(7);
' || fail "core.ip is_cloudflare_shared_cidr validation failed"

# 2. Test singbox.generator_routes load_community_subnet_cidrs filtering
# Create temporary /tmp/sing-box/rulesets if needed or link to TMP_DIR
mkdir -p /tmp/sing-box/rulesets
cp "$DISCORD_LST" /tmp/sing-box/rulesets/community-subnets-discord.lst
cp "$OTHER_LST" /tmp/sing-box/rulesets/community-subnets-other.lst

ucode -L "$LIB_DIR" -e '
let generator_routes = require("singbox.generator_routes");
let discord_cidrs = generator_routes.load_community_subnet_cidrs("discord");
if (!discord_cidrs || length(discord_cidrs) != 2) {
    warn("Unexpected discord_cidrs length: " + length(discord_cidrs) + "\n");
    exit(1);
}
for (let c in discord_cidrs) {
    if (c == "104.16.0.0/12" || c == "172.64.0.0/13" || c == "162.158.0.0/15" || c == "2606:4700::/32") {
        warn("Found Cloudflare CIDR in discord_cidrs: " + c + "\n");
        exit(2);
    }
}
if (discord_cidrs[0] != "66.22.196.0/22" || discord_cidrs[1] != "162.159.128.0/21") {
    warn("Expected subnets not found: " + discord_cidrs + "\n");
    exit(3);
}

// Ensure non-discord service is NOT stripped of Cloudflare CIDRs
let other_cidrs = generator_routes.load_community_subnet_cidrs("other");
if (length(other_cidrs) != 2) exit(4);
' || fail "singbox.generator_routes load_community_subnet_cidrs filtering failed"

# Clean up /tmp test files
rm -f /tmp/sing-box/rulesets/community-subnets-discord.lst /tmp/sing-box/rulesets/community-subnets-other.lst

# 3. Test core.ip against discord file lines
ucode -L "$LIB_DIR" -e '
let fs = require("fs");
let core_ip = require("core.ip");

let data = fs.readfile("'"$DISCORD_LST"'");
let result = [];
for (let line in split(data, "\n")) {
    line = trim(replace(line, /\r/g, ""));
    if (line == "" || substr(line, 0, 1) == "#") continue;
    if (core_ip.is_cloudflare_shared_cidr(line)) continue;
    push(result, line);
}
if (length(result) != 2) exit(1);
if (result[0] != "66.22.196.0/22" || result[1] != "162.159.128.0/21") exit(2);
' || fail "community subnet lines filtering failed"

# 4. Test diagnostics/runtime.uc resolve-domain mode
output="$(ucode -L "$LIB_DIR" "$LIB_DIR/diagnostics/runtime.uc" resolve-domain "127.0.0.1" 2>/dev/null || true)"
# Output should be valid JSON array (e.g. ["127.0.0.1"] or [] if nslookup filters loopback)
echo "$output" | grep -q '^\[' || fail "diagnostics/runtime.uc resolve-domain must output a JSON array"

printf 'All community subnets sanitization tests PASSED!\n'
