#!/usr/bin/env bash
# Every path that could send a Fail-Closed (fail_policy=block) section's traffic
# out directly while Tachyon is running. Each case is checked against the same
# setup with fail_policy=keep, so the old behaviour stays where it belongs.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"
NFT_RUNTIME="$TACHYON_LIB/nft/apply.uc"

generate() {
  mkdir -p "$2.section-cache"
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture "$1" "$2" "127.0.0.1" >/dev/null 2>"$2.err" || { cat "$2.err" >&2; false; } ||
    fail "generator rejected $(basename "$1"): $(tail -3 "$2.err")"
}

# --- 1. Direct priority level: never part of a Fail-Closed chain -------------
for policy in block keep; do
  cat >"$WORK_DIR/direct-level-$policy.json" <<JSON
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [ {
    ".name": "proxy", ".type": "section", "enabled": "1", "action": "proxy", "fail_policy": "$policy",
    "selector_proxy_links": [
      "vless://00000000-0000-4000-8000-000000000001@alpha.example:443?encryption=none&security=tls&sni=alpha.example#Alpha"
    ]
  } ],
  "priority_group": [ { ".name": "pg", ".type": "priority_group", "section": "proxy", "name": "Chain" } ],
  "priority_level": [
    { ".name": "pl_vpn", ".type": "priority_level", "group": "pg", "name": "VPN", "order": "0", "filter_mode": "disabled" },
    { ".name": "pl_direct", ".type": "priority_level", "group": "pg", "name": "Direct", "order": "1", "direct": "1" }
  ]
}
JSON
  generate "$WORK_DIR/direct-level-$policy.json" "$WORK_DIR/direct-level-$policy-config.json"
done
ucode -e '
let fs = require("fs");
function members(path) {
    for (let o in json(fs.readfile(path)).outbounds || [])
        if (o && o.tag == "proxy-priority-pg-out")
            return o.outbounds || [];
    die("priority selector missing in " + path + "\n");
}
if (index(members(ARGV[0]), "direct-out") >= 0)
    die("Fail-Closed priority chain still falls back to Direct\n");
if (index(members(ARGV[1]), "direct-out") < 0)
    die("Direct level vanished from a keep section\n");
' "$WORK_DIR/direct-level-block-config.json" "$WORK_DIR/direct-level-keep-config.json"

# --- 2. TCP-only outbound: client-wide UDP must not go direct ----------------
for policy in block keep; do
  cat >"$WORK_DIR/tcp-only-$policy.json" <<JSON
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [ {
    ".name": "proxy", ".type": "section", "enabled": "1", "action": "proxy", "fail_policy": "$policy",
    "fully_routed_ips": [ "192.168.1.50" ],
    "selector_proxy_links": [ "http://user:pass@tcp-only.example:8080#TcpOnly" ]
  } ]
}
JSON
  generate "$WORK_DIR/tcp-only-$policy.json" "$WORK_DIR/tcp-only-$policy-config.json"
done
ucode -e '
let fs = require("fs");
function udp_action(path) {
    for (let r in (json(fs.readfile(path)).route || {}).rules || []) {
        let src = r.source_ip_cidr;
        if (r.network == "udp" && src && index(type(src) == "array" ? src : [ src ], "192.168.1.50/32") >= 0)
            return r.action == "route" ? "route:" + r.outbound : r.action;
    }
    return "none";
}
let block = udp_action(ARGV[0]), keep = udp_action(ARGV[1]);
if (block != "reject")
    die("Fail-Closed client UDP over a TCP-only outbound is " + block + ", not rejected\n");
if (index(keep, "route:") != 0)
    die("keep section lost its UDP route (" + keep + ")\n");
' "$WORK_DIR/tcp-only-block-config.json" "$WORK_DIR/tcp-only-keep-config.json"

# --- 3. DoH reject in the core: on by default with Fail-Closed, user may opt out
sed 's/"settings": { ".name": "settings", ".type": "settings" }/"settings": { ".name": "settings", ".type": "settings", "dns_intercept_all": "0" }/' \
  "$WORK_DIR/tcp-only-block.json" >"$WORK_DIR/tcp-only-block-optout.json"
generate "$WORK_DIR/tcp-only-block-optout.json" "$WORK_DIR/tcp-only-block-optout-config.json"
ucode -e '
let fs = require("fs");
function doh_rejects(path) {
    for (let r in (json(fs.readfile(path)).route || {}).rules || [])
        if (r.action == "reject" && r.ip_cidr && index(type(r.ip_cidr) == "array" ? r.ip_cidr : [ r.ip_cidr ], "1.1.1.1/32") >= 0)
            return true;
    return false;
}
if (!doh_rejects(ARGV[0]))
    die("Fail-Closed did not force the core DoH reject\n");
if (doh_rejects(ARGV[1]))
    die("DoH reject appeared without block_doh, dns_intercept_all or Fail-Closed\n");
if (doh_rejects(ARGV[2]))
    die("dns_intercept_all=0 was overridden by Fail-Closed: clients cannot use their own DNS\n");
// DoH by name and the iCloud Private Relay canaries: NXDOMAIN with the intercept on.
function name_blocked(path, name) {
    for (let r in (json(fs.readfile(path)).dns || {}).rules || [])
        if (r.action == "predefined" && r.rcode == "NXDOMAIN" &&
            index(type(r.domain_suffix) == "array" ? r.domain_suffix : [ r.domain_suffix ], name) >= 0)
            return true;
    return false;
}
for (let name in [ "dns.google", "cloudflare-dns.com", "mask.icloud.com" ]) {
    if (!name_blocked(ARGV[0], name))
        die("Fail-Closed (Auto) does not answer NXDOMAIN for " + name + "\n");
    if (name_blocked(ARGV[1], name) || name_blocked(ARGV[2], name))
        die(name + " blocked without the LAN DNS intercept\n");
}
' "$WORK_DIR/tcp-only-block-config.json" "$WORK_DIR/tcp-only-keep-config.json" "$WORK_DIR/tcp-only-block-optout-config.json"

# --- 4. nft: forward leak guard, tproxy mode only ----------------------------
NFT_LOG="$WORK_DIR/nft.log"
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/nft" <<'NFT_STUB'
#!/usr/bin/env bash
{ printf 'nft'; for arg in "$@"; do printf '\t%s' "$arg"; done; printf '\n'; } >> "${NFT_LOG:?}"
exit 0
NFT_STUB
chmod +x "$WORK_DIR/bin/nft"
export PATH="$WORK_DIR/bin:$PATH" NFT_LOG

# Positional: ... block_doh disable_quic dns_intercept leak_guard webrtc fakeip_enabled fail_closed
base_args=(nft-create-runtime-base TachyonTable localv4 tachyon_subnets
  tachyon_ports tachyon_ip_ports tachyon_interfaces "br-lan" 0x00100000
  0x00200000 198.18.0.0/15 1602 0 "" "" "" "" "" 0 0 0 0 0 1)
GUARD=$'nft\tadd\trule\tinet\tTachyonTable\tfail_closed_forward\tiifname\t@tachyon_interfaces\tmeta\tmark\t&\t0x00100000\t==\t0x00100000\tcounter\tdrop'

run_base() {
  : >"$NFT_LOG"
  printf 'tachyon.settings=settings\ntachyon.settings.proxy_mode=%s\n' "$2" >"$WORK_DIR/mode.state"
  TACHYON_UCI_STATE_FILE="$WORK_DIR/mode.state" \
    ucode -L "$TACHYON_LIB" "$NFT_RUNTIME" "${base_args[@]}" "$1" >/dev/null
}
run_base 1 tproxy
grep -Fq "$GUARD" "$NFT_LOG" || fail "Fail-Closed tproxy runtime has no forward leak guard"
grep -Fq $'fail_closed_forward\t{ type filter hook forward priority -200; policy accept; }' "$NFT_LOG" ||
  fail "forward leak guard chain is not on the forward hook"
run_base 0 tproxy
if grep -Fq 'fail_closed_forward' "$NFT_LOG"; then fail "forward leak guard installed without Fail-Closed"; fi
# TUN routes by the core, not by the tproxy mark: the guard would drop real traffic.
run_base 1 tun
if grep -Fq 'fail_closed_forward' "$NFT_LOG"; then fail "forward leak guard installed in tun mode"; fi

# --- 5. nft from UCI: Fail-Closed forces the LAN DNS intercept ---------------
grep -Fq 'let dns_intercept = kill_switch.dns_intercept_effective(settings, fail_closed);' "$NFT_RUNTIME" ||
  fail "Fail-Closed must turn the LAN DNS intercept on by default"

# --- 6. No servers loaded yet: the direct placeholder must not carry traffic --
# The selector gets a direct member only to stay valid; a Fail-Closed section is
# quarantined instead, so its route rules reject until the cache is populated.
TACHYON_UCI_STATE_FILE="$WORK_DIR/none.state" ucode -L "$TACHYON_LIB" -e '
let gr = require("tachyon_core.generator_routes");
function quarantined(policy) {
    let ctx = {
        runtime_settings: function() { return {}; },
        detect_core_version: function() { return "0.5.7"; },
        download_detour_tag: function() { return ""; },
        current_section: null
    };
    gr.init(ctx);
    gr.add_proxy_selector({ outbounds: [], route: { rules: [] } },
        { ".name": "vpn", ".type": "section", action: "proxy", fail_policy: policy }, [], [], {}, "");
    return !!(ctx.quarantined_sections && ctx.quarantined_sections.vpn);
}
if (!quarantined("block"))
    die("Fail-Closed section with no servers falls back to direct\n");
if (quarantined("keep"))
    die("keep section with no servers was quarantined\n");
' 2>/dev/null || fail "empty-subscription Fail-Closed section is not quarantined"

printf 'fail-closed leak tests passed\n'
