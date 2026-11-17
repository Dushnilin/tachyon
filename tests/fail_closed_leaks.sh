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
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture "$1" "$2" "127.0.0.1" "${@:3}" >/dev/null 2>"$2.err" || { cat "$2.err" >&2; false; } ||
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
GUARD=$'nft\tadd\trule\tinet\tTachyonTable\tfail_closed_forward\tiifname\t@tachyon_interfaces\tmeta\tmark\t&\t0x00100000\t==\t0x00100000'

run_base() { # $1 fail_closed, $2 proxy_mode, $3 routing_strategy
  : >"$NFT_LOG"
  printf 'tachyon.settings=settings\ntachyon.settings.proxy_mode=%s\ntachyon.settings.routing_strategy=%s\n' \
    "$2" "${3:-split}" >"$WORK_DIR/mode.state"
  TACHYON_UCI_STATE_FILE="$WORK_DIR/mode.state" \
    ucode -L "$TACHYON_LIB" "$NFT_RUNTIME" "${base_args[@]}" "$1" >/dev/null
}
run_base 1 tproxy
grep -Fq "$GUARD"$'\tcounter\tdrop' "$NFT_LOG" || fail "Fail-Closed tproxy runtime has no forward leak guard"
grep -Fq $'fail_closed_forward\t{ type filter hook forward priority -200; policy accept; }' "$NFT_LOG" ||
  fail "forward leak guard chain is not on the forward hook"
if grep -Fq 'tachyon-fail-closed-full-tunnel' "$NFT_LOG"; then fail "full-tunnel guard installed in split mode"; fi
run_base 0 tproxy
if grep -Fq 'fail_closed_forward' "$NFT_LOG"; then fail "forward leak guard installed without Fail-Closed"; fi
# TUN: the core's auto_route forwards marked packets into tun0; when the core
# dies they would go out via WAN, so only the tun device may take them.
run_base 1 tun
grep -Fq "$GUARD"$'\toifname\t!=\t"tun0"\tcounter\tdrop' "$NFT_LOG" || fail "Fail-Closed tun runtime does not keep marked packets inside tun"
run_base 1 socks
if grep -Fq 'fail_closed_forward' "$NFT_LOG"; then fail "forward leak guard installed in socks mode"; fi
# Full tunnel: tproxy carries only TCP/UDP, so ICMP/GRE/ESP would go direct.
FT_RULE=$'iifname\t@tachyon_interfaces\tip\tdaddr\t!=\t@localv4\tmeta\tmark\t0\tmeta\tl4proto\t!=\t{ tcp, udp }\tct\tstate\tnew'
run_base 1 tproxy full_tunnel
grep -Fq "$FT_RULE"$'\tcounter\tdrop' "$NFT_LOG" || fail "Fail-Closed full tunnel (tproxy) forwards non-TCP/UDP directly"
run_base 1 tun full_tunnel
grep -Fq "$FT_RULE"$'\tmeta\tmark\tset\t0x00100000' "$NFT_LOG" || fail "Fail-Closed full tunnel (tun) leaves non-TCP/UDP unguarded"
run_base 0 tproxy full_tunnel
if grep -Fq 'tachyon-fail-closed-full-tunnel' "$NFT_LOG"; then fail "full-tunnel guard installed without Fail-Closed"; fi

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
        detect_sing_box_version: function() { return "1.12.0"; },
        download_detour_tag: function() { return ""; },
        current_section: null
    };
    gr.init(ctx);
    gr.add_proxy_selector({ outbounds: [], route: { rules: [] } },
        { ".name": "vpn", ".type": "section", action: "fptn", fail_policy: policy }, [], [], {}, "");
    return !!(ctx.quarantined_sections && ctx.quarantined_sections.vpn);
}
if (!quarantined("block"))
    die("Fail-Closed section with no servers falls back to direct\n");
if (quarantined("keep"))
    die("keep section with no servers was quarantined\n");
' 2>/dev/null || fail "empty-subscription Fail-Closed section is not quarantined"

# --- 7. Full tunnel: the catch-all must not move to Direct or another section --
# A deferred (subscription not fetched yet, e.g. right after boot) or
# quarantined default tunnel section used to drop the catch-all: everything then
# fell through to route.final (Direct) or to whatever section came next.
# Direct exceptions (bypass sections) keep working either way.
VPN_LINK='"vless://00000000-0000-4000-8000-000000000001@alpha.example:443?encryption=none&security=tls&sni=alpha.example#Alpha"'
full_tunnel_fixture() { # $1 policy, $2 out
  cat >"$2" <<JSON
{
  "settings": { ".name": "settings", ".type": "settings",
    "routing_strategy": "full_tunnel", "default_tunnel_section": "vpn" },
  "section": [
    { ".name": "ru_direct", ".type": "section", "enabled": "1", "action": "bypass",
      "domain_suffix": [ "example.ru" ] },
    { ".name": "vpn", ".type": "section", "enabled": "1", "action": "proxy", "fail_policy": "$1",
      "selector_proxy_links": [ $VPN_LINK ] },
    { ".name": "other", ".type": "section", "enabled": "1", "action": "proxy", "fail_policy": "keep",
      "domain_suffix": [ "other.example" ],
      "selector_proxy_links": [
        "vless://00000000-0000-4000-8000-000000000002@beta.example:443?encryption=none&security=tls&sni=beta.example#Beta"
      ] }
  ]
}
JSON
}
for policy in block keep; do
  full_tunnel_fixture "$policy" "$WORK_DIR/ft-$policy.json"
  generate "$WORK_DIR/ft-$policy.json" "$WORK_DIR/ft-$policy-config.json"
  # after the service address: mwan3, xhttp, deferred sections, quarantined sections
  generate "$WORK_DIR/ft-$policy.json" "$WORK_DIR/ft-$policy-deferred-config.json" 0 1 vpn ""
  generate "$WORK_DIR/ft-$policy.json" "$WORK_DIR/ft-$policy-quarantined-config.json" 0 1 "" vpn
done
ucode -e '
let fs = require("fs");
function arr(v) { return type(v) == "array" ? v : (v == null ? [] : [ v ]); }
// The catch-all: a route rule matching only the LAN (tproxy) inbound.
function catch_all(path) {
    let found = "none";
    for (let r in (json(fs.readfile(path)).route || {}).rules || []) {
        let k = filter(keys(r), (x) => x != "action" && x != "outbound" && x != "network");
        if (index(arr(r.inbound), "tproxy-in") >= 0 && length(k) == 1 && (r.network == null || r.network == "tcp"))
            found = r.action == "route" ? "route:" + r.outbound : r.action;
    }
    return found;
}
function bypass_direct(path) {
    for (let r in (json(fs.readfile(path)).route || {}).rules || [])
        if (index([ "direct-out", "bypass-out" ], r.outbound) >= 0 && index(arr(r.domain_suffix), "example.ru") >= 0)
            return true;
    return false;
}
let got = map(ARGV, catch_all);
let ok_block = got[0], def_block = got[1], q_block = got[2], ok_keep = got[3], def_keep = got[4];
if (index(ok_block, "route:") != 0 || index(ok_block, "vpn") < 0)
    die("healthy Fail-Closed full tunnel does not route to its section (" + ok_block + ")\n");
if (def_block != "reject")
    die("Fail-Closed full tunnel with a deferred section goes " + def_block + ", not reject\n");
if (q_block != "reject")
    die("Fail-Closed full tunnel with a quarantined section goes " + q_block + ", not reject\n");
if (index(ok_keep, "vpn") < 0 || def_keep == "reject")
    die("keep full tunnel changed (" + ok_keep + " / " + def_keep + ")\n");
for (let p in ARGV)
    if (!bypass_direct(p))
        die("direct exception lost in " + p + "\n");
' "$WORK_DIR/ft-block-config.json" "$WORK_DIR/ft-block-deferred-config.json" "$WORK_DIR/ft-block-quarantined-config.json" \
  "$WORK_DIR/ft-keep-config.json" "$WORK_DIR/ft-keep-deferred-config.json"

# --- 8. Upgrades: the stored '0' (old default) becomes 'auto' once -----------
# Releases before 'auto' wrote dns_intercept_all and webrtc_leak_protect '0'
# into every config, which would keep both off under Fail-Closed forever. A '0' set after the
# migration is the user's choice and stays.
MIGRATION_UC="$TACHYON_LIB/config/migration.uc"
for applied in no yes; do
  extra=""
  [ "$applied" = yes ] && extra=', "fail_closed_auto_defaults"'
  cat >"$WORK_DIR/mig-$applied.json" <<JSON
{ "settings": { ".name": "settings", ".type": "settings", "config_version": "1.0.5", "dns_intercept_all": "0", "webrtc_leak_protect": "0",
    "applied_migrations": [ "interface_sections", "enable_component_checks", "http_connection_urls",
      "dns_hosts_to_option", "global_hosts_to_section", "orphan_section_interface_cleanup",
      "ensure_dns_server_defaults", "engine_identity_tachyon_core", "modular_entities_v1",
      "priority_levels_to_outbound_groups", "relax_probe_intervals_v1", "ensure_tcp_bbr_default"$extra ] },
  "section": [] }
JSON
  ucode -L "$TACHYON_LIB" "$MIGRATION_UC" migrate-fixture "$WORK_DIR/mig-$applied.json" tachyon >"$WORK_DIR/mig-$applied-out.json" ||
    fail "migration fixture failed ($applied)"
done
ucode -e '
let fs = require("fs");
let a = json(fs.readfile(ARGV[0])).config.settings;
let b = json(fs.readfile(ARGV[1])).config.settings;
for (let key in [ "dns_intercept_all", "webrtc_leak_protect" ]) {
    if (a[key] != "auto")
        die("upgrade kept the old default " + key + "=" + a[key] + ": Fail-Closed would not turn it on\n");
    if (b[key] != "0")
        die("explicit " + key + "=0 after the migration was overridden (" + b[key] + ")\n");
}
' "$WORK_DIR/mig-no-out.json" "$WORK_DIR/mig-yes-out.json"

# --- 9. WebRTC: direct STUN/TURN hands a proxied site the real address --------
# Auto (the default) drops it while a section is Fail-Closed; 0 is honoured.
ucode -L "$TACHYON_LIB" -e '
let ks = require("service.kill_switch");
let cases = [
    [ {}, true, true ], [ {}, false, false ],
    [ { webrtc_leak_protect: "auto" }, true, true ],
    [ { webrtc_leak_protect: "0" }, true, false ],
    [ { webrtc_leak_protect: "1" }, false, true ]
];
for (let c in cases)
    if (ks.webrtc_protect_effective(c[0], c[1]) != c[2])
        die(sprintf("webrtc_protect_effective(%J, fail_closed=%J) != %J\n", c[0], c[1], c[2]));
' || fail "WebRTC leak protection does not follow Fail-Closed"
grep -Fq 'kill_switch.webrtc_protect_effective(settings, fail_closed) ? "1" : "0",' "$NFT_RUNTIME" ||
  fail "nft runtime does not apply the Fail-Closed WebRTC default"

printf 'fail-closed leak tests passed\n'
