#!/bin/sh

set -eu

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TACHYON_LIB="$REPO_ROOT/tachyon/files/usr/lib"
VALIDATOR_UC="$TACHYON_LIB/config/validator.uc"
NFT_APPLY_UC="$TACHYON_LIB/nft/apply.uc"
SETTINGS_JS="$REPO_ROOT/luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/settings.js"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    file="$1"
    needle="$2"
    message="$3"

    grep -Fq -- "$needle" "$file" || fail "$message"
}

assert_contains "$SETTINGS_JS" '"wifi_calling_direct"' "settings.js must expose wifi_calling_direct option"
assert_contains "$SETTINGS_JS" '"bittorrent_policy"' "settings.js must expose bittorrent_policy option"

WORK_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

# 1. Test singbox/route.uc rules for wifi_calling_direct and bittorrent_policy (off / direct / block + legacy isolate_p2p)
ucode -L "$TACHYON_LIB" -e '
let route = require("singbox.route");

// Legacy isolate_p2p=1 maps to direct
let cfg_legacy = route.config({
    isolate_p2p: "1",
    p2p_ports: "tcp:6881,udp:6881-6889"
}, {});
let found_legacy_bt = false;
let found_legacy_port = false;
for (let r in cfg_legacy.rules) {
    if (r.protocol == "bittorrent" && r.action == "route" && r.outbound == "direct-out")
        found_legacy_bt = true;
    if (r.source_port == 6881 && r.action == "route" && r.outbound == "direct-out")
        found_legacy_port = true;
}
if (!found_legacy_bt || !found_legacy_port) {
    warn("legacy isolate_p2p failed: " + sprintf("%J", cfg_legacy.rules) + "\n");
    exit(1);
}

// bittorrent_policy=block rejects protocol:bittorrent and p2p_ports
let cfg_block = route.config({
    bittorrent_policy: "block",
    p2p_ports: "tcp:6881,udp:6881-6889",
    wifi_calling_direct: "1"
}, {});
let found_bt_reject = false;
let found_port_reject = false;
let found_range_reject = false;
let found_vowifi = false;
for (let r in cfg_block.rules) {
    if (r.protocol == "bittorrent" && r.action == "reject" && r.outbound == null)
        found_bt_reject = true;
    if (r.source_port == 6881 && r.action == "reject" && r.outbound == null)
        found_port_reject = true;
    if (type(r.port_range) == "array" && r.port_range[0] == "6881:6889" && r.action == "reject")
        found_range_reject = true;
    if (r.network == "udp" && type(r.port) == "array" && r.port[0] == 500 && r.port[1] == 4500 && r.outbound == "direct-out")
        found_vowifi = true;
}
if (!found_bt_reject || !found_port_reject || !found_range_reject || !found_vowifi) {
    warn("cfg_block assertions failed: " + sprintf("%J", cfg_block.rules) + "\n");
    exit(1);
}
' || fail "singbox/route.uc wifi_calling_direct and bittorrent_policy test failed"

# 2. Test nft/apply.uc and service/state.uc signatures change when wifi_calling_direct or bittorrent_policy changes
cat >"$WORK_DIR/fixture-base.json" <<'EOF'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "source_network_interfaces": "br-lan"
  },
  "section": []
}
EOF

cat >"$WORK_DIR/fixture-vowifi.json" <<'EOF'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "source_network_interfaces": "br-lan",
    "wifi_calling_direct": "1"
  },
  "section": []
}
EOF

sig_base="$(ucode -L "$TACHYON_LIB" "$NFT_APPLY_UC" nft-runtime-signature-fixture "$WORK_DIR/fixture-base.json")"
sig_vowifi="$(ucode -L "$TACHYON_LIB" "$NFT_APPLY_UC" nft-runtime-signature-fixture "$WORK_DIR/fixture-vowifi.json")"
[ -n "$sig_base" ] && [ -n "$sig_vowifi" ] && [ "$sig_base" != "$sig_vowifi" ] ||
    fail "nft runtime signature must change when wifi_calling_direct is toggled"

# 3. Test config/validator.uc rejects invalid bittorrent_policy and accepts valid ones
cat >"$WORK_DIR/fixture-invalid-bt.json" <<'EOF'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "bootstrap_dns_server": "1.1.1.1",
    "bittorrent_policy": "invalid-mode"
  },
  "section": []
}
EOF

if ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-fixture "$WORK_DIR/fixture-invalid-bt.json" '{}' >/dev/null 2>&1; then
    fail "validator.uc must reject invalid bittorrent_policy"
fi

cat >"$WORK_DIR/fixture-valid-bt.json" <<'EOF'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "bootstrap_dns_server": "1.1.1.1",
    "bittorrent_policy": "block",
    "wifi_calling_direct": "1"
  },
  "section": []
}
EOF

ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-fixture "$WORK_DIR/fixture-valid-bt.json" '{}' >/dev/null ||
    fail "validator.uc must accept valid bittorrent_policy=block and wifi_calling_direct=1"

printf 'PASS: wifi_calling_direct and bittorrent_policy verified\n'
