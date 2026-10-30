#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
GENERATOR="$TACHYON_LIB/tachyon_core/generator.uc"
RULESETS="$TACHYON_LIB/tachyon_core/rulesets.uc"
LIFECYCLE="$TACHYON_LIB/service/lifecycle.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_path": "/tmp/tachyon-core/config.json",
    "dns_type": "doh",
    "dns_server": [ "https://dns.google/dns-query" ],
    "bootstrap_dns_server": [ "77.88.8.8" ],
    "disable_quic": "0",
    "routing_strategy": "split"
  },
  "section": [
    {
      ".name": "RuDNS",
      ".type": "section",
      "enabled": "1",
      "action": "dns",
      "dns_type": "doh",
      "dns_server": [ "https://common.dot.dns.yandex.net/dns-query" ],
      "community_lists": [ "russia_outside" ],
      "condition_refs": [ "cond_RuDNS" ]
    },
    {
      ".name": "yt",
      ".type": "section",
      "enabled": "1",
      "action": "desync",
      "desync_preset": "tlsrec",
      "community_lists": [ "youtube" ],
      "source_ip_cidr": [ "192.168.10.222/32" ]
    },
    {
      ".name": "bye",
      ".type": "section",
      "enabled": "1",
      "action": "byedpi",
      "byedpi_cmd_opts": "-s1 -s3+s -r1+s -S",
      "condition_refs": [ "cond_bye" ]
    },
    {
      ".name": "Discord",
      ".type": "section",
      "enabled": "1",
      "action": "desync",
      "desync_preset": "auto",
      "desync_opts": "mode=fake_split split_pos=2 fake_ttl=8 fake_sni=max.ru repeats=8",
      "desync_mode": "fake_split",
      "desync_split_pos": "2",
      "desync_fake_ttl": "8",
      "desync_fake_sni": "max.ru",
      "desync_repeats": "8",
      "community_lists": [ "discord" ],
      "community_subnets": "1"
    }
  ],
  "condition": [
    {
      ".name": "cond_RuDNS",
      ".type": "condition",
      "enabled": "1",
      "condition_type": "atomic",
      "community_lists": [ "russia_outside" ]
    },
    {
      ".name": "cond_bye",
      ".type": "condition",
      "enabled": "1",
      "condition_type": "atomic",
      "community_lists": [ "youtube" ],
      "source_ip_cidr": [ "192.168.10.119/32" ]
    }
  ]
}
JSON

TACHYON_LIB="$TACHYON_LIB" \
SB_VERSION_OVERRIDE="0.2.1" \
SB_VARIANT_OVERRIDE="tachyon-core" \
  ucode -L "$TACHYON_LIB" "$GENERATOR" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$WORK_DIR/out.json" "127.0.0.1" "0" "1"

ucode -L "$TACHYON_LIB" -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));

function assert(cond, msg) {
    if (!cond) {
        warn("FAIL: " + msg + "\n");
        exit(1);
    }
}

function as_arr(v) {
    if (v == null) return [];
    return type(v) == "array" ? v : [ v ];
}

function has(arr, item) {
    for (let x in as_arr(arr))
        if (x == item) return true;
    return false;
}

let dns_rules = cfg.dns.rules || [];
let rudns_idx = -1;
let yt_idx = -1;
let bye_idx = -1;
let fallback_rule = null;

for (let i = 0; i < length(dns_rules); i++) {
    let r = dns_rules[i];
    if (r.server == "RuDNS-dns-server" && has(r.rule_set, "RuDNS-russia_outside-community-ruleset"))
        rudns_idx = i;
    if (r.server == "fakeip-server" && has(r.rule_set, "yt-youtube-community-ruleset"))
        yt_idx = i;
    if (r.server == "fakeip-server" && has(r.rule_set, "bye-youtube-community-ruleset"))
        bye_idx = i;
    if (r.server == "dnsmasq-server" && has(r.inbound, "source-dns-in"))
        fallback_rule = r;
}

assert(yt_idx >= 0 && bye_idx >= 0 && rudns_idx >= 0,
    sprintf("expected yt (%d), bye (%d), and RuDNS (%d) DNS rules", yt_idx, bye_idx, rudns_idx));
assert(yt_idx < rudns_idx && bye_idx < rudns_idx,
    sprintf("FakeIP DNS rules (yt=%d, bye=%d) must precede RuDNS (%d)", yt_idx, bye_idx, rudns_idx));

assert(fallback_rule != null, "source-dns-in fallback rule must exist");
assert(has(fallback_rule.source_ip_cidr, "192.168.10.222/32") && has(fallback_rule.source_ip_cidr, "192.168.10.119/32"),
    "source-dns-in fallback must include source_ip_cidr from both section and condition_refs");

let route_rules = cfg.route.rules || [];
let yt_udp_reject = -1;
let yt_tcp_route = -1;
let bye_udp_reject = -1;
let bye_tcp_route = -1;

for (let i = 0; i < length(route_rules); i++) {
    let r = route_rules[i];
    if (r.action == "reject" && has(r.network, "udp") && has(r.rule_set, "yt-youtube-community-ruleset"))
        yt_udp_reject = i;
    if (r.outbound == "yt-out" && has(r.network, "tcp") && has(r.rule_set, "yt-youtube-community-ruleset"))
        yt_tcp_route = i;
    if (r.action == "reject" && has(r.network, "udp") && has(r.rule_set, "bye-youtube-community-ruleset"))
        bye_udp_reject = i;
    if (r.outbound == "bye-out" && has(r.network, "tcp") && has(r.rule_set, "bye-youtube-community-ruleset"))
        bye_tcp_route = i;
}

assert(yt_udp_reject >= 0 && yt_tcp_route > yt_udp_reject,
    sprintf("TCP-only desync must reject UDP before TCP route (udp=%d, tcp=%d)", yt_udp_reject, yt_tcp_route));
assert(bye_udp_reject >= 0 && bye_tcp_route > bye_udp_reject,
    sprintf("ByeDPI must reject UDP before TCP route (udp=%d, tcp=%d)", bye_udp_reject, bye_tcp_route));

let discord_udp_reject = -1;
let discord_route = -1;
for (let i = 0; i < length(route_rules); i++) {
    let r = route_rules[i];
    if (r.action == "reject" && has(r.network, "udp") && has(r.rule_set, "Discord-discord-community-ruleset"))
        discord_udp_reject = i;
    if (r.outbound == "Discord-out" && has(r.rule_set, "Discord-discord-community-ruleset"))
        discord_route = i;
}
assert(discord_udp_reject < 0 && discord_route >= 0,
    sprintf("Desync with preset=auto must support UDP and NOT reject Discord UDP (reject=%d, route=%d)", discord_udp_reject, discord_route));
' -- "$WORK_DIR/out.json"

grep -Fq '" >/dev/null"' "$RULESETS" ||
  fail "rulesets.uc srs_file_parses must redirect stdout to /dev/null"

grep -Fq 'append_reload_action(actions, plan.needs_sing_box_reload, "tachyon-core")' "$LIFECYCLE" ||
  fail "lifecycle.uc reload_actions_summary must label reload as tachyon-core"

# Verify newly created Priority & URLTest balancers with AmneziaWG + Subscription sources
ucode -L "$TACHYON_LIB" - <<'UCODE'
let connections = require("config.connections");
let routes = require("tachyon_core.generator_routes");
let subscription = require("tachyon_core.subscription");

function assert(cond, msg) {
    if (!cond) {
        warn("FAIL: " + msg + "\n");
        exit(1);
    }
}

let fixture = {
    outbound_source: [
        {
            ".name": "src_awg_main",
            ".type": "outbound_source",
            enabled: "1",
            name: "AmneziaWG Main",
            source_type: "awg",
            awg_private_key: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            awg_server_address: "198.51.100.10",
            awg_server_port: "51820",
            awg_peer_public_key: "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=",
            awg_local_address: [ "10.8.1.2/32" ]
        },
        {
            ".name": "src_sub_vless",
            ".type": "outbound_source",
            enabled: "1",
            name: "VLESS Sub",
            source_type: "subscription",
            url: "https://sub.example.com/vless",
            prefix_nodes: "0"
        }
    ],
    outbound_group: [
        {
            ".name": "grp_awg_only",
            ".type": "outbound_group",
            enabled: "1",
            name: "AWG Group",
            source_refs: [ "src_awg_main" ],
            filter_mode: "include"
        }
    ],
    balancer: [
        {
            ".name": "bal_new_prio_direct_sources",
            ".type": "balancer",
            enabled: "1",
            name: "New Priority (Direct Sources)",
            balancer_type: "priority",
            outbound_group_levels: [ "src_awg_main", "src_sub_vless", "direct" ]
        },
        {
            ".name": "bal_new_prio_pool",
            ".type": "balancer",
            enabled: "1",
            name: "New Priority (Section Pool)",
            balancer_type: "priority"
        },
        {
            ".name": "bal_new_urltest_include",
            ".type": "balancer",
            enabled: "1",
            name: "New URLTest Include AWG",
            balancer_type: "urltest",
            filter_mode: "include",
            include_proxy_parameters: "1",
            include_protocols: [ "amneziawg" ]
        }
    ],
    section: [
        {
            ".name": "Main",
            ".type": "section",
            enabled: "1",
            action: "connection",
            outbound_source_refs: [ "src_awg_main", "src_sub_vless" ],
            balancer_refs: [ "bal_new_prio_direct_sources", "bal_new_prio_pool", "bal_new_urltest_include" ]
        },
        {
            ".name": "SingleAwgSec",
            ".type": "section",
            enabled: "1",
            action: "connection",
            outbound_group_refs: [ "grp_awg_only" ]
        }
    ]
};

connections.set_item_sections_from_data(fixture);

let state = subscription.new_section_state("Main");
let candidates = [ "Main-1-out", "vless-de-1", "vless-nl-2" ];
state.outboundMetadata.names = {
    "Main-1-out": "AmneziaWG Main",
    "vless-de-1": "🇩🇪 Germany #1",
    "vless-nl-2": "🇳🇱 Netherlands #2"
};
state.outboundMetadata.protocols = {
    "Main-1-out": "wireguard",
    "vless-de-1": "vless",
    "vless-nl-2": "vless"
};
state.outboundMetadata.sources = {
    "Main-1-out": "src_awg_main",
    "vless-de-1": "sub:1",
    "vless-nl-2": "sub:1"
};
state.outboundMetadata.source_ids = {
    "vless-de-1": "src_sub_vless",
    "vless-nl-2": "src_sub_vless"
};

let cfg = { outbounds: [], route: { rules: [] }, dns: { servers: [], rules: [] } };
routes.add_proxy_selector(cfg, fixture.section[0], candidates, candidates, state, "");

let by_tag = {};
for (let o in cfg.outbounds)
    by_tag[o.tag] = o;

let prio1 = by_tag["Main-priority-bal_new_prio_direct_sources-out"];
assert(prio1 != null, "Priority balancer with outbound_source IDs in outbound_group_levels must be emitted");
assert(length(prio1.outbounds) == 4 &&
    prio1.outbounds[0] == "Main-1-out" &&
    prio1.outbounds[1] == "vless-de-1" &&
    prio1.outbounds[2] == "vless-nl-2" &&
    prio1.outbounds[3] == "direct-out",
    "Priority balancer must order AmneziaWG first, then VLESS subscription nodes, then direct-out, got: " + sprintf("%J", prio1.outbounds));

let prio2 = by_tag["Main-priority-bal_new_prio_pool-out"];
assert(prio2 != null, "Priority balancer with empty outbound_group_levels (Section Pool) must be emitted");
assert(length(prio2.outbounds) == 3 && prio2.outbounds[0] == "Main-1-out",
    "Section Pool Priority balancer must include section sources in order, got: " + sprintf("%J", prio2.outbounds));

let ut1 = by_tag["Main-urltest-bal_new_urltest_include-out"];
assert(ut1 != null, "URLTest balancer with include_protocols=['amneziawg'] must be emitted");
assert(length(ut1.outbounds) == 1 && ut1.outbounds[0] == "Main-1-out",
    "include_protocols=['amneziawg'] must match wireguard/amneziawg endpoint, got: " + sprintf("%J", ut1.outbounds));

// Verify single-source section with outbound_group (filter_mode='include' and no extra criteria) does not drop all outbounds
let single_state = subscription.new_section_state("SingleAwgSec");
single_state.outboundMetadata.names = { "SingleAwgSec-1-out": "AmneziaWG Main" };
single_state.outboundMetadata.sources = { "SingleAwgSec-1-out": "src_awg_main" };
let single_cfg = { outbounds: [], route: { rules: [] }, dns: { servers: [], rules: [] } };
routes.add_proxy_selector(single_cfg, fixture.section[1], [ "SingleAwgSec-1-out" ], [ "SingleAwgSec-1-out" ], single_state, "");
let single_sel = null;
for (let o in single_cfg.outbounds)
    if (o.tag == "SingleAwgSec-out")
        single_sel = o;
assert(single_sel != null && length(single_sel.outbounds) == 1 && single_sel.outbounds[0] == "SingleAwgSec-1-out",
    "Single-source section with outbound_group (filter_mode=include) must retain its outbound, got: " + sprintf("%J", single_sel));

// Verify Adaptive Desync 2.0 presets, modes, fooling, and auto_tune
let outbounds_gen = require("tachyon_core.generator_outbounds");
outbounds_gen.init({
    detect_sing_box_version: function() { return "0.2.3"; },
    ensure_sing_box_variant_supported: function() { return true; },
    runtime_generate_unsupported: function(msg) { warn("FAIL: " + msg + "\n"); exit(1); }
});
let desync_cfg = { outbounds: [] };
outbounds_gen.add_desync_outbound(desync_cfg, {
    ".name": "sec_auto",
    desync_preset: "auto",
    desync_fooling: "md5",
    desync_auto_tune: "1"
});
let ob_auto = desync_cfg.outbounds[0];
assert(ob_auto != null && ob_auto.tag == "sec_auto-out" && ob_auto.preset == "auto" && ob_auto.fooling == "md5" && ob_auto.auto_tune === true,
    "Adaptive Desync 2.0 auto preset with fooling=md5 and auto_tune=true must be preserved, got: " + sprintf("%J", ob_auto));

outbounds_gen.add_desync_outbound(desync_cfg, {
    ".name": "sec_custom",
    desync_preset: "custom",
    desync_mode: "fake_disorder",
    desync_split_pos: "sni",
    desync_fake_ttl: "4",
    desync_fooling: "autottl",
    desync_auto_tune: "0"
});
let ob_custom = desync_cfg.outbounds[1];
assert(ob_custom != null && ob_custom.tag == "sec_custom-out" && ob_custom.mode == "fake_disorder" && ob_custom.fooling == "autottl" && ob_custom.auto_tune === false && ob_custom.split_pos == "sni" && ob_custom.fake_ttl == 4,
    "Custom fake_disorder mode with fooling=autottl and auto_tune=false must be preserved, got: " + sprintf("%J", ob_custom));

// Verify non-custom preset (e.g. "auto") ignores leftover custom fuzzer fields (desync_opts, desync_mode)
// while preserving explicit Adaptive 2.0 overrides (fake_sni, split_pos, fake_ttl, repeats)
// and that outbound_supports_udp treats preset="auto" / "fake_split" / "fake_disorder" / "fake" as UDP-capable
outbounds_gen.add_desync_outbound(desync_cfg, {
    ".name": "sec_auto_dirty",
    desync_preset: "auto",
    desync_opts: "mode=fake_split split_pos=2 fake_ttl=8 fake_sni=max.ru repeats=8",
    desync_mode: "fake_split",
    desync_split_pos: "2",
    desync_fake_ttl: "8",
    desync_fake_sni: "max.ru",
    desync_repeats: "8"
});
let ob_auto_dirty = desync_cfg.outbounds[2];
assert(ob_auto_dirty != null && ob_auto_dirty.preset == "auto" && ob_auto_dirty.mode == null && ob_auto_dirty.split_pos == 2 && ob_auto_dirty.fake_sni == "max.ru" && ob_auto_dirty.fake_ttl == 8 && ob_auto_dirty.repeats == 8,
    "Preset='auto' must ignore leftover desync_mode/desync_opts while preserving explicit Adaptive 2.0 overrides, got: " + sprintf("%J", ob_auto_dirty));

let src_desync_dirty = {
    ".name": "DesyncSrc",
    ".type": "outbound_source",
    enabled: "1",
    source_type: "desync",
    desync_preset: "auto",
    desync_opts: "mode=fake_split split_pos=2 fake_ttl=8 fake_sni=max.ru repeats=8",
    desync_mode: "fake_split",
    desync_split_pos: "2",
    desync_fake_ttl: "8",
    desync_fake_sni: "max.ru",
    desync_repeats: "8"
};
let disc_sec = {
    ".name": "Discord",
    ".type": "section",
    enabled: "1",
    action: "connection",
    outbound_source_refs: [ "DesyncSrc" ]
};
connections.set_item_sections_from_data({
    outbound_source: [ src_desync_dirty ],
    section: [ disc_sec ]
});
let disc_links = connections.outbound_jsons(disc_sec);
assert(length(disc_links) == 1, "expected 1 synthesized desync JSON link for Discord section");
let disc_ob = json(disc_links[0]);
assert(disc_ob.preset == "auto" && disc_ob.mode == null && disc_ob.split_pos == 2 && disc_ob.fake_sni == "max.ru",
    "Synthesized outbound_source desync JSON with preset='auto' must ignore leftover desync_mode while preserving Adaptive 2.0 overrides, got: " + disc_links[0]);

// Verify subscription parser filters out 127.0.0.1 traffic/quota banner nodes (e.g. socks://127.0.0.1:1080#tTest|📊2.00GB)
let sub_parser = require("subscription.parser");
let stub_node = sub_parser.parse_share_link("socks://127.0.0.1:1080#tTest%7C%F0%9F%93%8A2.00GB", "stub-tag");
let real_node = sub_parser.parse_share_link("vless://11111111-2222-3333-4444-555555555555@example.com:443?security=tls&sni=example.com#RealNode", "real-tag");
assert(sub_parser.outbound_is_unsupported_stub(stub_node) === true,
    "outbound_is_unsupported_stub must recognize 127.0.0.1 quota/info banner node as a stub");
assert(sub_parser.outbound_is_unsupported_stub(real_node) === false,
    "outbound_is_unsupported_stub must not mark real node as a stub");

// Verify rulesets.uc accepts TSRS magic header
let fs_mod = require("fs");
let rulesets_mod = require("tachyon_core.rulesets");
let tsrs_path = "/tmp/test_faceit_tsrs_" + time() + ".trs";
fs_mod.writefile(tsrs_path, "TSRS\x01\x00\x00\x00\x01\x00\x00\x00faceit.com");
assert(rulesets_mod.is_valid_trs_file(tsrs_path) === true,
    "is_valid_trs_file must accept TSRS magic header");
fs_mod.unlink(tsrs_path);

// Verify updater.uc tachyon_core_asset_is_foreign_platform rejects Android / macOS / Windows / gnu assets
let updater_src = fs_mod.readfile(getenv("TACHYON_LIB") + "/components/updater.uc");
assert(index(updater_src, "tachyon_core_asset_is_foreign_platform") >= 0 &&
    index(updater_src, "android") >= 0 &&
    index(updater_src, "unknown-linux-musl-") >= 0,
    "updater.uc must filter out Android/foreign assets and prioritize musl builds");
UCODE

printf 'PASS: bugreport_rudns_desync_byedpi\n'
