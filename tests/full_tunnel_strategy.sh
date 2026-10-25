#!/usr/bin/env bash
# Tests for Global Routing Strategy: «Full Tunnel with Exceptions» (Всё в туннель, кроме исключений)
# 1. UI: settings.js exposes routing_strategy and default_tunnel_section.
# 2. Validator: validates routing_strategy and ensures an active proxy section is available.
# 3. Generator: emits catch-all route rule pointing to default tunnel section,
#    placed after section-specific rules and bypass rules.
# 4. NFT: emits full-tunnel marking rules in prerouting mangle when routing_strategy=full_tunnel.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

SETTINGS_JS="$ROOT_DIR/luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/settings.js"
VALIDATOR_UC="$TACHYON_LIB/config/validator.uc"
GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"
NFT_APPLY_UC="$TACHYON_LIB/nft/apply.uc"

# 1. UI declarations
grep -Fq '"routing_strategy"' "$SETTINGS_JS" ||
  fail "settings.js must declare routing_strategy option"
grep -Fq '"default_tunnel_section"' "$SETTINGS_JS" ||
  fail "settings.js must declare default_tunnel_section option"

# 2. Validator tests
STUB_BIN="$WORK_DIR/bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/logger" <<'BASH'
#!/usr/bin/env bash
exit 0
BASH
chmod +x "$STUB_BIN/logger"

validate_fixture() {
  local fixture="$1"
  TACHYON_LIB="$TACHYON_LIB" PATH="$STUB_BIN:$PATH" \
    ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-fixture "$fixture" '{}'
}

# 2a. Invalid routing_strategy value fails
cat >"$WORK_DIR/fixture-invalid-strategy.json" <<'EOF'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "bootstrap_dns_server": "1.1.1.1",
    "routing_strategy": "crazy_mode"
  },
  "section": []
}
EOF
if validate_fixture "$WORK_DIR/fixture-invalid-strategy.json" >/dev/null 2>&1; then
  fail "validator must reject unsupported routing_strategy"
fi

# 2b. full_tunnel without any proxy section fails
cat >"$WORK_DIR/fixture-no-proxy.json" <<'EOF'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "bootstrap_dns_server": "1.1.1.1",
    "routing_strategy": "full_tunnel"
  },
  "section": [
    {
      ".name": "direct_sec",
      ".type": "section",
      "enabled": "1",
      "action": "bypass"
    }
  ]
}
EOF
if validate_fixture "$WORK_DIR/fixture-no-proxy.json" >/dev/null 2>&1; then
  fail "validator must reject full_tunnel without active proxy sections"
fi

# 2c. full_tunnel with nonexistent default_tunnel_section fails
cat >"$WORK_DIR/fixture-bad-target.json" <<'EOF'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "bootstrap_dns_server": "1.1.1.1",
    "routing_strategy": "full_tunnel",
    "default_tunnel_section": "nonexistent"
  },
  "section": [
    {
      ".name": "proxy_sec",
      ".type": "section",
      "enabled": "1",
      "action": "connection"
    }
  ]
}
EOF
if validate_fixture "$WORK_DIR/fixture-bad-target.json" >/dev/null 2>&1; then
  fail "validator must reject nonexistent default_tunnel_section"
fi

# 2d. Valid full_tunnel passes validation
cat >"$WORK_DIR/fixture-valid.json" <<'EOF'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "bootstrap_dns_server": "1.1.1.1",
    "routing_strategy": "full_tunnel",
    "default_tunnel_section": "vpn_main"
  },
  "section": [
    {
      ".name": "vpn_main",
      ".type": "section",
      "enabled": "1",
      "action": "connection"
    }
  ]
}
EOF
validate_fixture "$WORK_DIR/fixture-valid.json" >/dev/null ||
  fail "validator must accept valid full_tunnel configuration"

# 3. Generator tests: catch-all rule and bypass ordering
LINK_VPN="vless://00000000-0000-4000-8000-000000000001@example.com:443?encryption=none&security=tls&sni=example.com#nodeVPN"

cat >"$WORK_DIR/fixture-full-tunnel.json" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "log_level": "warn",
    "routing_strategy": "full_tunnel",
    "default_tunnel_section": "vpn_sec"
  },
  "section": [
    {
      ".name": "russia_inside",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "user_domains": [ "gosuslugi.ru", "sberbank.ru" ]
    },
    {
      ".name": "vpn_sec",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [ "$LINK_VPN" ]
    }
  ]
}
JSON

output_ft="$WORK_DIR/ft-config.json"
mkdir -p "${output_ft}.section-cache"

TACHYON_LIB="$TACHYON_LIB" PATH="$STUB_BIN:$PATH" \
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
    "$WORK_DIR/fixture-full-tunnel.json" "$output_ft" "127.0.0.1"

ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));

let full_tunnel_rule_idx = -1;
let bypass_rule_idx = -1;

for (let i = 0; i < length(cfg.route.rules || []); i++) {
    let r = cfg.route.rules[i];
    let inbounds = type(r.inbound) == "array" ? r.inbound : (r.inbound != null ? [ r.inbound ] : []);
    if (r.action == "route" && r.outbound == "vpn_sec-out" && index(inbounds, "tproxy-in") >= 0 && r.domain == null && r.ip_cidr == null && r.rule_set == null) {
        full_tunnel_rule_idx = i;
    }
    if (r.action == "route" && (r.outbound == "bypass-out" || r.outbound == "direct-out") && (r.domain != null || r.domain_suffix != null || r.rule_set != null)) {
        bypass_rule_idx = i;
    }
}

if (full_tunnel_rule_idx < 0)
    die("catch-all full tunnel rule missing from route.rules\n");

if (bypass_rule_idx < 0)
    die("bypass route rule missing from route.rules\n");

if (bypass_rule_idx >= full_tunnel_rule_idx)
    die("bypass route rule must appear BEFORE full tunnel catch-all rule, got bypass at " + bypass_rule_idx + " and full_tunnel at " + full_tunnel_rule_idx + "\n");
' "$output_ft" || fail "generator full tunnel route ordering check failed"

# 4. NFT rules and signature tests
NFT_LOG="$WORK_DIR/nft.log"
export NFT_LOG
: > "$NFT_LOG"
cat >"$STUB_BIN/nft" <<'SH'
#!/usr/bin/env bash
{
  printf 'nft'
  for arg in "$@"; do
    printf '\t%s' "$arg"
  done
  printf '\n'
} >> "${NFT_LOG:?}"
SH
chmod +x "$STUB_BIN/nft"

cat >"$STUB_BIN/modprobe" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$STUB_BIN/modprobe"

cat >"$STUB_BIN/ip" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$STUB_BIN/ip"

# 4a. In split mode (default), tachyon-full-tunnel is not added
: > "$NFT_LOG"
cat >"$WORK_DIR/uci-split.state" <<'EOF'
tachyon.settings=settings
tachyon.settings.routing_strategy=split
EOF
UCI_STATE="$WORK_DIR/uci-split.state" PATH="$STUB_BIN:$PATH" \
  ucode -L "$TACHYON_LIB" "$NFT_APPLY_UC" nft-create-runtime-base \
    TachyonTable localv4 tachyon_subnets tachyon_ports tachyon_ip_ports tachyon_interfaces "br-lan" \
    0x04000000 0x08000000 198.18.0.0/15 1602 0 localv6 tachyon_subnets6 tachyon_ip6_ports fc00::/18 ::1 0 off

if grep -Fq 'tachyon-full-tunnel' "$NFT_LOG"; then
  fail "split mode must not insert tachyon-full-tunnel rule"
fi

# 4b. In full_tunnel mode, tachyon-full-tunnel rule is added to mangle
: > "$NFT_LOG"
cat >"$WORK_DIR/uci-ft.state" <<'EOF'
tachyon.settings=settings
tachyon.settings.routing_strategy=full_tunnel
tachyon.settings.default_tunnel_section=vpn_sec
tachyon.vpn_sec=section
tachyon.vpn_sec.enabled=1
tachyon.vpn_sec.action=connection
EOF
UCI_STATE="$WORK_DIR/uci-ft.state" PATH="$STUB_BIN:$PATH" \
  ucode -L "$TACHYON_LIB" "$NFT_APPLY_UC" nft-create-runtime-base \
    TachyonTable localv4 tachyon_subnets tachyon_ports tachyon_ip_ports tachyon_interfaces "br-lan" \
    0x04000000 0x08000000 198.18.0.0/15 1602 0 localv6 tachyon_subnets6 tachyon_ip6_ports fc00::/18 ::1 0 off

grep -Fq 'tachyon-full-tunnel' "$NFT_LOG" ||
  fail "full_tunnel mode must insert tachyon-full-tunnel rule into mangle"

# 4c. Signature check: signature changes between split and full_tunnel
cat >"$WORK_DIR/nft-fixture-split.json" <<'EOF'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "routing_strategy": "split"
  },
  "section": []
}
EOF

cat >"$WORK_DIR/nft-fixture-ft.json" <<'EOF'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "routing_strategy": "full_tunnel",
    "default_tunnel_section": "vpn_sec"
  },
  "section": [
    {
      ".name": "vpn_sec",
      ".type": "section",
      "enabled": "1",
      "action": "connection"
    }
  ]
}
EOF

SIG_SPLIT=$(ucode -L "$TACHYON_LIB" "$NFT_APPLY_UC" nft-runtime-signature-fixture "$WORK_DIR/nft-fixture-split.json")
SIG_FT=$(ucode -L "$TACHYON_LIB" "$NFT_APPLY_UC" nft-runtime-signature-fixture "$WORK_DIR/nft-fixture-ft.json")

if [ -z "$SIG_SPLIT" ] || [ -z "$SIG_FT" ]; then
  fail "NFT runtime signature must not be empty"
fi

if [ "$SIG_SPLIT" = "$SIG_FT" ]; then
  fail "NFT runtime signature must differ between split and full_tunnel strategies"
fi

printf 'full_tunnel_strategy: OK\n'
