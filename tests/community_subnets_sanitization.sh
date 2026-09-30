#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
LIB_DIR="$ROOT_DIR/tachyon/files/usr/lib"

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

# 2. Test singbox.generator_routes load_community_subnet_cidrs filtering and voice extraction
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
        warn("Found Cloudflare CIDR in general discord_cidrs: " + c + "\n");
        exit(2);
    }
}
if (discord_cidrs[0] != "66.22.196.0/22" || discord_cidrs[1] != "162.159.128.0/21") {
    warn("Expected subnets not found: " + discord_cidrs + "\n");
    exit(3);
}

// Ensure load_community_subnet_cidrs("discord", "only_cloudflare") extracts the 4 Cloudflare CIDRs for voice
let discord_cf = generator_routes.load_community_subnet_cidrs("discord", "only_cloudflare");
if (length(discord_cf) != 4) {
    warn("Expected 4 Cloudflare voice subnets, got: " + length(discord_cf) + "\n");
    exit(4);
}

// Ensure non-discord service is NOT stripped of Cloudflare CIDRs
let other_cidrs = generator_routes.load_community_subnet_cidrs("other");
if (length(other_cidrs) != 2) exit(5);
' || fail "singbox.generator_routes load_community_subnet_cidrs filtering failed"

# 3. Test sing-box route generation for Discord section
# Keep the test community-subnets-discord.lst present
cp "$DISCORD_LST" /tmp/sing-box/rulesets/community-subnets-discord.lst

ucode -L "$LIB_DIR" -e '
let fs = require("fs");
let generator_routes = require("singbox.generator_routes");
generator_routes.init({
    runtime_settings: () => ({}),
    runtime_ruleset_folder: "/tmp/sing-box/rulesets",
    download_detour_tag: (settings, kind) => "direct-out",
    runtime_generate_unsupported: (msg) => { warn(msg + "\n"); exit(1); }
});

let config = {
    route: { rules: [] },
    dns: { rules: [] },
    outbounds: [
        { type: "direct", tag: "direct-out" },
        { type: "direct", tag: "sec_discord-out" }
    ]
};
let section = {
    ".name": "sec_discord",
    "action": "outbound",
    "outbound": "direct-out",
    "community_lists": [ "discord" ],
    "community_subnets": "1"
};

generator_routes.add_combined_route_for_section(config, section);

let found_general_ip = false;
let found_voice_udp = false;

for (let r in config.route.rules) {
    if (r.ip_cidr && !r.network) {
        // General IP rule must only contain non-Cloudflare CIDRs
        for (let c in r.ip_cidr) {
            if (c == "104.16.0.0/12" || c == "172.64.0.0/13" || c == "162.158.0.0/15" || c == "2606:4700::/32") {
                warn("Cloudflare CIDR leaked into general IP rule: " + c + "\n");
                exit(2);
            }
        }
        found_general_ip = true;
    }
    if (r.ip_cidr && r.network == "udp") {
        // Voice rule must have port_range restricting to voice ports
        if (!r.port_range || length(r.port_range) == 0) {
            warn("Voice UDP rule missing port_range restriction!\n");
            exit(3);
        }
        let has_cf_voice_ports = false;
        for (let p in r.port_range) {
            if (p == "19294:19344") has_cf_voice_ports = true;
        }
        if (!has_cf_voice_ports) {
            warn("Voice UDP rule missing 19294:19344 port range!\n");
            exit(6);
        }
        found_voice_udp = true;
    }
}

if (!found_general_ip) {
    warn("Missing general IP route rule for Discord\n");
    exit(4);
}
if (!found_voice_udp) {
    warn("Missing dedicated UDP voice route rule for Discord Cloudflare Anycast subnets\n");
    exit(5);
}

fs.writefile("/tmp/test_discord_singbox.json", sprintf("%J", config));
' || fail "sing-box Discord route generation verification failed"

# Verify sing-box parses the generated route rules without error (if binary is present)
if command -v sing-box >/dev/null 2>&1; then
    sing-box check -c /tmp/test_discord_singbox.json || fail "sing-box check failed on generated Discord voice rules"
fi
rm -f /tmp/test_discord_singbox.json

# Clean up /tmp test files
rm -f /tmp/sing-box/rulesets/community-subnets-discord.lst /tmp/sing-box/rulesets/community-subnets-other.lst

# 4. Test fallback to DEFAULT_DISCORD_VOICE_SUBNETS when ruleset file is missing / empty
ucode -L "$LIB_DIR" -e '
let generator_routes = require("singbox.generator_routes");
let fallback_cf = generator_routes.load_community_subnet_cidrs("discord", "only_cloudflare");
if (!fallback_cf || length(fallback_cf) != 4) {
    warn("Fallback voice subnets failed: " + length(fallback_cf) + "\n");
    exit(1);
}
let has_104 = false;
for (let c in fallback_cf) {
    if (c == "104.16.0.0/12") has_104 = true;
}
if (!has_104) {
    warn("Fallback voice subnets missing 104.16.0.0/12\n");
    exit(2);
}
' || fail "singbox.generator_routes fallback voice subnets failed"

# 5. Test core.ip against discord file lines
ucode -L "$LIB_DIR" -e '
let fs = require("fs");
let core_ip = require("core.ip");

let data = fs.readfile("'"$DISCORD_LST"'");
let result = [];
let cf_result = [];
for (let line in split(data, "\n")) {
    line = trim(replace(line, /\r/g, ""));
    if (line == "" || substr(line, 0, 1) == "#") continue;
    if (core_ip.is_cloudflare_shared_cidr(line)) {
        push(cf_result, line);
        continue;
    }
    push(result, line);
}
if (length(result) != 2) exit(1);
if (result[0] != "66.22.196.0/22" || result[1] != "162.159.128.0/21") exit(2);
if (length(cf_result) != 4) exit(3);
' || fail "community subnet lines filtering failed"

# 6. Test diagnostics/runtime.uc resolve-domain mode
output="$(ucode -L "$LIB_DIR" "$LIB_DIR/diagnostics/runtime.uc" resolve-domain "127.0.0.1" 2>/dev/null || true)"
# Output should be valid JSON array (e.g. ["127.0.0.1"] or [] if nslookup filters loopback)
echo "$output" | grep -q '^\[' || fail "diagnostics/runtime.uc resolve-domain must output a JSON array"

printf 'All community subnets sanitization tests PASSED!\n'

