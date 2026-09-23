#!/bin/bash
# Tests for core/engine.uc and components/engine_state.uc — the multi-core
# routing-engine orchestrator.
#
# Verifies:
#   - engine registry and capability matrix
#   - feature -> unsupported mapping for a switch
#   - switch plan parks configuration the target engine cannot express
#   - switching back restores what was parked
#   - switch is refused when the target engine is not installed
#   - UCI option read/write through the fixture backend

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TACHYON_LIB="${TACHYON_LIB:-$SCRIPT_DIR/../tachyon/files/usr/lib}"
TACHYON_BIN="${TACHYON_BIN:-$SCRIPT_DIR/../tachyon/files/usr/bin/tachyon}"
TACHYON_UCODE="${TACHYON_UCODE:-ucode}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

pass=0
fail=0

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    fail=$((fail + 1))
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass=$((pass + 1))
    else
        fail_test "$label: expected '$expected', got '$actual'"
    fi
}

assert_true() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        pass=$((pass + 1))
    else
        fail_test "$label: command failed: $*"
    fi
}

assert_match() {
    local label="$1" pattern="$2" actual="$3"
    # No grep -q here: under `set -o pipefail` a -q match can close the pipe
    # before echo finishes writing, and the resulting EPIPE flips this branch.
    if echo "$actual" | grep -E "$pattern" >/dev/null; then
        pass=$((pass + 1))
    else
        fail_test "$label: expected pattern '$pattern', got '$actual'"
    fi
}

run_uc() {
    $TACHYON_UCODE -L "$TACHYON_LIB" -e "$1" 2>&1
}

# ---------------------------------------------------------------------------
# Engine registry and capability matrix
# ---------------------------------------------------------------------------

printf '%s\n' '--- engine registry ---'
out="$(run_uc '
let e = require("core.engine");
let known = e.known_engines();
print("count=" + length(known) + "\n");
print("has_singbox=" + e.engine_is_known("sing-box") + "\n");
print("has_steer=" + e.engine_is_known("steer") + "\n");
print("has_ext=" + e.engine_is_known("steer-extended") + "\n");
print("has_bogus=" + e.engine_is_known("nonsense") + "\n");
')"
assert_match "registry lists engines" 'count=3' "$out"
assert_match "sing-box is known" 'has_singbox=true' "$out"
assert_match "steer is known" 'has_steer=true' "$out"
assert_match "steer-extended is known" 'has_ext=true' "$out"
assert_match "unknown engine rejected" 'has_bogus=false' "$out"

printf '%s\n' '--- capability matrix ---'
out="$(run_uc '
let e = require("core.engine");
print("sb_sub=" + e.supports("sing-box", "sections.subscription") + "\n");
print("sb_vless=" + e.supports("sing-box", "outbound.vless_reality") + "\n");
print("steer_sub=" + e.supports("steer", "sections.subscription") + "\n");
print("steer_fit=" + e.supports("steer", "list_memory_fit") + "\n");
print("ext_vless=" + e.supports("steer-extended", "outbound.vless_reality") + "\n");
print("ext_sub=" + e.supports("steer-extended", "sections.subscription") + "\n");
')"
assert_match "sing-box supports subscriptions" 'sb_sub=true' "$out"
assert_match "sing-box supports vless" 'sb_vless=true' "$out"
assert_match "steer cannot express subscriptions" 'steer_sub=false' "$out"
assert_match "steer supports list fit" 'steer_fit=true' "$out"
assert_match "steer-extended supports vless" 'ext_vless=true' "$out"
assert_match "steer-extended cannot express subscriptions" 'ext_sub=false' "$out"

printf '%s\n' '--- unsupported feature mapping ---'
out="$(run_uc '
let e = require("core.engine");
let feats = [ "sections.subscription", "routing.domain_lists", "outbound.vless_reality", "list_memory_fit" ];
let to_steer = e.unsupported_features("steer", feats);
print("to_steer=" + join(",", to_steer) + "\n");
let to_sb = e.unsupported_features("sing-box", feats);
print("to_sb=" + join(",", to_sb) + "\n");
let summary = e.unsupported_summary("sing-box", "steer", feats);
print("loses=" + summary.loses_features + "\n");
')"
assert_match "steer parks subscription" 'to_steer=sections.subscription' "$out"
assert_match "steer parks vless" 'to_steer=.*outbound.vless_reality' "$out"
assert_match "sing-box parks fit" 'to_sb=list_memory_fit' "$out"
assert_match "switch reports feature loss" 'loses=true' "$out"

# ---------------------------------------------------------------------------
# Switch plan: park and restore
# ---------------------------------------------------------------------------

printf '%s\n' '--- switch plan parks incompatible config ---'
out="$(TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state" run_uc '
let e = require("core.engine");
let feats = [ "sections.subscription", "routing.domain_lists" ];
let plan = e.plan_switch("steer", feats);
print("from=" + plan.from_engine + "\n");
print("to=" + plan.to_engine + "\n");
print("unsupported=" + join(",", plan.unsupported) + "\n");
print("parked_sub=" + (plan.parked["sections.subscription"] != null) + "\n");
print("parked_domains=" + (plan.parked["routing.domain_lists"] != null) + "\n");
')"
assert_match "plan from sing-box" 'from=sing-box' "$out"
assert_match "plan to steer" 'to=steer' "$out"
assert_match "plan parks subscription" 'parked_sub=true' "$out"
assert_match "plan parks only incompatible" 'parked_domains=false' "$out"

printf '%s\n' '--- parked payload round-trips through UCI ---'
out="$(TACHYON_UCI_STATE_FILE="$WORK_DIR/uci2.state" run_uc '
let e = require("core.engine");
e.write_parked("steer", { "sections.subscription": "main" });
let back = e.read_parked("steer");
print("restored=" + back["sections.subscription"] + "\n");
')"
assert_match "parked payload restores" 'restored=main' "$out"

printf '%s\n' '--- feature map carries section names ---'
out="$(run_uc '
let e = require("core.engine");
let map = { "sections.subscription": [ "sub_main", "sub_backup" ], "routing.domain_lists": [ "main" ] };
let plan = e.plan_switch("steer", map);
print("parked_names=" + join(",", plan.parked["sections.subscription"]) + "\n");
print("has_domains=" + (plan.parked["routing.domain_lists"] != null) + "\n");
')"
assert_match "parked payload names sections" 'parked_names=sub_main,sub_backup' "$out"
assert_match "compatible feature not parked" 'has_domains=false' "$out"

# ---------------------------------------------------------------------------
# Module selftests
# ---------------------------------------------------------------------------

printf '%s\n' '--- steer list catalog ---'
out="$(run_uc '
let l = require("steer.lists");
let manifest = l.parse_manifest("{ \"base_url\": \"https://x/lists\", \"categories\": [ {\"id\":\"telegram\",\"file\":\"telegram.lst\",\"default_on\":true}, {\"id\":\"netflix\",\"file\":\"netflix.lst\",\"default_on\":false} ], \"domain_lists\": [ {\"id\":\"porn\",\"file\":\"domains/porn.lst\",\"default_on\":false}, {\"id\":\"news\",\"file\":\"domains/news.lst\",\"default_on\":true} ] }");
print("parsed=" + (manifest != null) + "\n");
let cats = l.select_categories(manifest, []);
print("default_cats=" + join(",", map(cats, function(e){ return e.id; })) + "\n");
let chosen = l.select_categories(manifest, [ "netflix" ]);
print("chosen_cats=" + join(",", map(chosen, function(e){ return e.id; })) + "\n");
let doms = l.select_domain_lists(manifest, []);
print("default_doms=" + join(",", map(doms, function(e){ return e.id; })) + "\n");
let probe = { file: "telegram.lst" };
print("url=" + l.category_url(manifest, probe) + "\n");
print("bad=" + (l.parse_manifest("not json") == null) + "\n");
')"
assert_match "manifest parses" 'parsed=true' "$out"
assert_match "default categories selected" 'default_cats=telegram' "$out"
assert_match "explicit category selected" 'chosen_cats=netflix' "$out"
assert_match "default domain lists selected" 'default_doms=news' "$out"
assert_match "category url built" 'url=https://x/lists/telegram.lst' "$out"
assert_match "bad manifest rejected" 'bad=true' "$out"

printf '%s\n' '--- catalog ids map into channels ---'
out="$(run_uc '
let g = require("steer.generator");
let sections = [
    { ".name": "tg", ".type": "section", "action": "connection", "enabled": "1", "label": "TG",
      "outbound_interfaces": [ "wg0" ] }
];
// The generator delegates list materialisation; assert it is invoked and its
// paths land in the channel match.
g.set_list_materializer(function(section, catalog) {
    return { domains: "/etc/steer/lists/channels/tg/domains.lst",
             prefixes: "/etc/steer/lists/channels/tg/prefixes.lst" };
});
let spec = g.build_spec(sections, {}, {});
print("domains=" + join(",", spec.channels[0].match.domains_files) + "\n");
print("prefixes=" + join(",", spec.channels[0].match.prefixes_files) + "\n");
')"
assert_match "materialised domain list referenced" 'domains=/etc/steer/lists/channels/tg/domains.lst' "$out"
assert_match "materialised prefix list referenced" 'prefixes=/etc/steer/lists/channels/tg/prefixes.lst' "$out"

printf '%s\n' '--- steer list materialisation ---'
MAT_DIR="$WORK_DIR/steer-lists"
mkdir -p "$MAT_DIR/channels"
cat >"$MAT_DIR/ref.lst" <<'EOF'
example.org
10.0.0.0/8
1.2.3.4
# comment
EOF
out="$(TACHYON_STEER_LISTS_DIR="$MAT_DIR" run_uc '
let l = require("steer.lists");
let section = { ".name": "kids", "user_domains": [ "inline.example" ],
    "user_domains_text": "text1.example text2.example",
    "domain_ip_lists": [ "'"$MAT_DIR"'/ref.lst" ] };
let res = l.materialize_section_lists(section, {});
print("domains_path=" + res.domains + "\n");
print("prefixes_path=" + res.prefixes + "\n");
')"
assert_match "domain list written" 'domains_path=.*channels/kids/domains.lst' "$out"
assert_match "prefix list written" 'prefixes_path=.*channels/kids/prefixes.lst' "$out"
if [ -f "$MAT_DIR/channels/kids/domains.lst" ]; then
    grep -q 'inline.example' "$MAT_DIR/channels/kids/domains.lst" &&
        grep -q 'example.org' "$MAT_DIR/channels/kids/domains.lst" &&
        grep -q 'text1.example' "$MAT_DIR/channels/kids/domains.lst" ||
        fail_test "materialised domains file is missing inline or referenced domains"
    grep -q '10.0.0.0/8' "$MAT_DIR/channels/kids/prefixes.lst" &&
        grep -q '1.2.3.4' "$MAT_DIR/channels/kids/prefixes.lst" ||
        fail_test "materialised prefixes file is missing CIDRs"
    grep -q 'comment' "$MAT_DIR/channels/kids/domains.lst" &&
        fail_test "materialised list must skip comments" || true
    pass=$((pass + 1))
else
    fail_test "domains.lst was not written"
fi

printf '%s\n' '--- steer spec generator ---'
out="$(run_uc '
let g = require("steer.generator");
let sections = [
    { ".name": "main", ".type": "section", "action": "connection", "enabled": "1",
      "label": "Main", "outbound_interfaces": [ "wg0", "awg0" ],
      "user_domains": [ "example.org" ], "domain_ip_lists": [ "/etc/tachyon/lists/x.lst" ] },
    { ".name": "kids", ".type": "section", "action": "bypass", "enabled": "1",
      "label": "Kids", "client_addresses": [ "192.168.1.50" ], "user_domains": [ "kids.example" ] },
    { ".name": "unsupported", ".type": "section", "action": "wdtt", "enabled": "1" }
];
g.set_list_materializer(function(section, catalog) {
    let d = [];
    for (let v in (section.user_domains || [])) push(d, v);
    let p = [];
    for (let v in (section.domain_ip_lists || [])) push(p, v);
    return { domains: length(d) ? "/tmp/" + section[".name"] + ".domains" : "",
             prefixes: length(p) ? "/tmp/" + section[".name"] + ".prefixes" : "" };
});
let spec = g.build_spec(sections, { "source_network_interfaces": [ "br-lan", "tailscale0" ] });
print("schema=" + spec.schema + "\n");
print("lan=" + join(",", spec.lan_devices) + "\n");
print("out_main=" + spec.outputs.Main.kind + "\n");
print("out_main_devices=" + join(",", spec.outputs.Main.devices) + "\n");
print("has_direct=" + (spec.outputs.direct != null) + "\n");
print("channels=" + length(spec.channels) + "\n");
print("ch0_out=" + spec.channels[0].out + "\n");
print("ch0_domains=" + join(",", spec.channels[0].match.domains_files) + "\n");
print("ch0_prefixes=" + join(",", spec.channels[0].match.prefixes_files) + "\n");
print("ch1_from=" + join(",", spec.channels[1].from) + "\n");
print("ch1_out=" + spec.channels[1].out + "\n");
print("no_wdtt=" + (spec.outputs.Unsupported == null && spec.outputs.unsupported == null) + "\n");
print("name_safe=" + g.safe_name("My Server / NL") + "\n");
')"
assert_match "spec schema 2" 'schema=2' "$out"
assert_match "lan devices from settings" 'lan=br-lan,tailscale0' "$out"
assert_match "interface output built" 'out_main=interface' "$out"
assert_match "device preference order kept" 'out_main_devices=wg0,awg0' "$out"
assert_match "direct output always present" 'has_direct=true' "$out"
assert_match "two channels generated" 'channels=2' "$out"
assert_match "first channel targets Main" 'ch0_out=Main' "$out"
assert_match "domain refs mapped" 'ch0_domains=/tmp/main.domains' "$out"
assert_match "subnet refs mapped" 'ch0_prefixes=/tmp/main.prefixes' "$out"
assert_match "client filter mapped" 'ch1_from=192.168.1.50' "$out"
assert_match "bypass channel goes direct" 'ch1_out=direct' "$out"
assert_match "unsupported section skipped" 'no_wdtt=true' "$out"
assert_match "unsafe names sanitized" 'name_safe=My_Server___NL' "$out"

printf '%s\n' '--- steer generator contract compliance ---'
out="$(run_uc '
let g = require("steer.generator");
let sections = [
    { ".name": "z2", ".type": "section", "action": "zapret2", "enabled": "1", "label": "Z2",
      "user_domains": [ "youtube.com" ], "ports": "443, 50000-65535", "proto": "udp" },
    { ".name": "macs", ".type": "section", "action": "connection", "enabled": "1",
      "label": "MacHosts", "outbound_interfaces": [ "wg0" ],
      "client_addresses": [ "AA:BB:CC:DD:EE:F0", "192.168.1.50/32" ],
      "mac_addresses": [ "11:22:33:44:55:66" ] },
    { ".name": "iface", ".type": "section", "action": "connection", "enabled": "1",
      "label": "Iface", "outbound_interfaces": [ "wg0" ],
      "client_addresses": [ "AA:BB:CC:DD:EE:F1" ] }
];
g.set_list_materializer(function(section, catalog) {
    let d = [];
    for (let v in (section.user_domains || [])) push(d, v);
    return { domains: length(d) ? "/tmp/" + section[".name"] + ".domains" : "", prefixes: "" };
});
let spec = g.build_spec(sections, {});
let zc = null;
for (let i = 0; i < length(spec.channels); i++)
    if (spec.channels[i].out == "Z2" && spec.channels[i].match.proto != null)
        zc = spec.channels[i];
print("z2_proto=" + (zc != null ? zc.match.proto : "none") + "\n");
print("z2_ports=" + (zc != null ? join("|", zc.match.ports) : "none") + "\n");
print("z2_realip=" + (zc != null && zc.match.mode == "realip" ? "1" : "0") + "\n");
let mac_chans = 0;
let dev_scoped = 0;
let mixed = 0;
for (let i = 0; i < length(spec.channels); i++) {
    let ch = spec.channels[i];
    if (ch.from == null) continue;
    let macs = 0;
    for (let v in ch.from) if (match(v, /:/) != null) macs++;
    if (macs > 0) {
        mac_chans++;
        if (macs != length(ch.from)) mixed++;
    }
    if (ch.scope == "device") dev_scoped++;
}
print("mac_channels=" + mac_chans + "\n");
print("mixed_from=" + mixed + "\n");
print("dev_scoped=" + dev_scoped + "\n");
' 2>&1)"
assert_match "zapret2 proto mapped" 'z2_proto=udp' "$out"
assert_match "ports written as strings" 'z2_ports=443|50000-65535' "$out"
assert_match "default fakeip mode (realip deprecated by steer 1.5.7+)" 'z2_realip=0' "$out"
assert_match "mac channel separated" 'mac_channels=2' "$out"
assert_match "addresses and macs never mixed" 'mixed_from=0' "$out"
assert_match "single hosts get device scope" 'dev_scoped=3' "$out"

printf '%s\n' '--- steer per-section subscription files ---'
SUB_CACHE_DIR="$WORK_DIR/section-cache"
mkdir -p "$SUB_CACHE_DIR"
cat >"$SUB_CACHE_DIR/sec_a.json" <<'EOF'
{ "links": { "proxy-0": "vless://a@example.com:443?type=tcp", "proxy-1": "vless://b@example.com:443?type=tcp" } }
EOF
cat >"$SUB_CACHE_DIR/sec_b.json" <<'EOF'
{ "links": { "proxy-0": "vless://c@other.example:443?type=tcp" } }
EOF
out="$(TACHYON_STEER_SUBS_DIR="$WORK_DIR/steer-subs" TACHYON_SECTION_CACHE_DIR="$SUB_CACHE_DIR" run_uc '
let l = require("steer.lists");
let a = l.write_subscription_file("sec_a");
let b = l.write_subscription_file("sec_b");
print("a=" + a + "\n");
print("b=" + b + "\n");
print("distinct=" + (a != b && a != "" && b != "") + "\n");
' 2>&1)"
assert_match "section A sub file" "a=$WORK_DIR/steer-subs/sec_a.txt" "$out"
assert_match "section B sub file" "b=$WORK_DIR/steer-subs/sec_b.txt" "$out"
assert_match "two sections do not overwrite each other" 'distinct=true' "$out"
grep -q 'vless://a@' "$WORK_DIR/steer-subs/sec_a.txt" && pass=$((pass + 1)) || fail_test "section A sub file content"

printf '%s\n' '--- steer section cache rebuild (singbox pipeline replacement) ---'
TMP_SUB_DIR="$WORK_DIR/subs-tmp"
mkdir -p "$TMP_SUB_DIR"
cat >"$TMP_SUB_DIR/sc-subscription-1.json" <<'EOF'
{ "outbounds": [
  { "type": "urltest", "tag": "auto-group", "remark": "Auto", "outbounds": ["NL-1", "DE-1"], "url": "https://www.gstatic.com/generate_204" },
  { "type": "vless", "tag": "NL-1", "remark": "Amsterdam", "server": "nl.example.com", "server_port": 443,
    "uuid": "14f2e88d-f48e-4ce8-bdc7-f46107be5ff0", "tls": { "enabled": true, "reality": { "enabled": true } } },
  { "type": "vless", "tag": "DE-1", "remark": "Berlin", "server": "de.example.com", "server_port": 443,
    "uuid": "14f2e88d-f48e-4ce8-bdc7-f46107be5ff0", "tls": { "enabled": true } },
  { "type": "selector", "tag": "groups", "outbounds": ["auto-group"] }
] }
EOF
SC_DIR="$WORK_DIR/section-cache-own"
mkdir -p "$SC_DIR"
cat >"$SC_DIR/sc.json" <<'EOF'
{ "subscriptionMetadata": [ { "title": "TestSub", "traffic": { "used": 1 } } ] }
EOF
out="$(TACHYON_CONFIG_NAME="tachyon" TACHYON_SECTION_CACHE_DIR="$SC_DIR" TMP_SUBSCRIPTION_FOLDER="$TMP_SUB_DIR" run_uc '
let fs = require("fs");
let sc = require("steer.section_cache");
let built = sc.build_section_cache({ ".name": "sc", "subscription_urls": [ "https://example.com/sub" ] });
print("built=" + built + "\n");
let cache = json(fs.readfile("'"$SC_DIR"'/sc.json"));
print("links=" + length(keys(cache.links)) + "\n");
print("nl_link=" + (match((cache.links["NL-1"] || ""), /^vless:\/\//) != null) + "\n");
print("group_children=" + join(",", cache.urltestGroups["auto-group"].outbounds) + "\n");
print("meta_kept=" + (cache.subscriptionMetadata[0].title == "TestSub") + "\n");
print("names=" + (cache.outboundMetadata.names["NL-1"] == "Amsterdam") + "\n");
' 2>&1)"
assert_match "section cache built" 'built=true' "$out"
assert_match "vless links recorded" 'links=2' "$out"
assert_match "vless link serialized" 'nl_link=true' "$out"
assert_match "urltest group remembered" 'group_children=NL-1,DE-1' "$out"
assert_match "subscription metadata preserved" 'meta_kept=true' "$out"
assert_match "display names remembered" 'names=true' "$out"

printf '%s\n' '--- zapret2 default strategy fallback ---'
ZAPRET_DIR="$WORK_DIR/steer-zapret"
rm -rf "$ZAPRET_DIR"
mkdir -p "$ZAPRET_DIR"
out="$(TACHYON_STEER_ZAPRET_DIR="$ZAPRET_DIR" TACHYON_STEER_LISTS_DIR="$WORK_DIR/steer-empty" run_uc '
let l = require("steer.lists");
l.materialize_section_lists({ ".name": "dz", "action": "zapret2", "label": "DZ" }, {});
print("done\n");
' 2>&1)"
if [ -f "$ZAPRET_DIR/DZ.opts" ]; then
    grep -q 'filter-tcp' "$ZAPRET_DIR/DZ.opts" && pass=$((pass + 1)) || fail_test "default zapret2 strategy not used for empty nfqws2_opt"
else
    fail_test "zapret2 default opts file not written"
fi

printf '%s\n' '--- zapret2 opts carry the full effective command line ---'
rm -rf "$ZAPRET_DIR"
mkdir -p "$ZAPRET_DIR"
mkdir -p "$WORK_DIR/fakefiles/fake"
printf 'fake-tls' > "$WORK_DIR/fakefiles/fake/tls_clienthello_www_google_com.bin"
printf 'fake-stun' > "$WORK_DIR/fakefiles/fake/stun.bin"
DISC_STRAT='--filter-tcp=443 --payload=tls_client_hello --lua-desync=fake:blob=tls_google:tcp_md5 --new --filter-udp=443 --lua-desync=fake:blob=discord_udp'
out="$(TACHYON_LIB="$TACHYON_LIB" TACHYON_STEER_ZAPRET_DIR="$ZAPRET_DIR" ZAPRET2_PROVIDER_FILES_DIR="$WORK_DIR/fakefiles" TACHYON_STEER_LISTS_DIR="$WORK_DIR/steer-empty" run_uc '
let l = require("steer.lists");
l.materialize_section_lists({ ".name": "disc", "action": "zapret2", "label": "DISC",
    "nfqws2_opt": "'"$DISC_STRAT"'" }, {});
print("done\n");
' 2>&1)"
if [ -f "$ZAPRET_DIR/DISC.opts" ]; then
    grep -q -- '--lua-init=@' "$ZAPRET_DIR/DISC.opts" ||
        fail_test "opts missing --lua-init: lua strategies cannot load their runtime"
    grep -q -- '--blob=tls_google:@' "$ZAPRET_DIR/DISC.opts" ||
        fail_test "opts missing resolved --blob for tls_google"
    grep -q -- '--blob=discord_udp:@' "$ZAPRET_DIR/DISC.opts" ||
        fail_test "opts missing resolved --blob for discord_udp"
    grep -q -- '--fwmark' "$ZAPRET_DIR/DISC.opts" &&
        fail_test "opts must not carry the provider fwmark (wrapper uses steer mark)" || true
    grep -q -- "$DISC_STRAT" "$ZAPRET_DIR/DISC.opts" ||
        fail_test "opts missing the user strategy"
    pass=$((pass + 1))
else
    fail_test "zapret2 opts file not written for section strategy"
fi

printf '%s\n' '--- spec nfqws_bin resolved from the provider ---'
out="$(run_uc '
let g = require("steer.generator");
let sections = [ { ".name": "z2b", ".type": "section", "action": "zapret2", "enabled": "1", "label": "Z2B",
    "user_domains": [ "youtube.com" ] } ];
g.set_list_materializer(function(section, catalog) {
    return { domains: "/tmp/z2b.domains", prefixes: "" };
});
let spec = g.build_spec(sections, {});
print("bin=" + spec.outputs.Z2B.nfqws_bin + "\n");
' 2>&1)"
case "$out" in
    bin=/opt/zapret2/nfq2/nfqws2|bin=/opt/zapret2/nfq/nfqws2|bin=/opt/zapret2/nfqws2|bin=/usr/bin/nfqws2)
        pass=$((pass + 1)) ;;
    *) fail_test "nfqws_bin not resolved from the provider candidate list: $out" ;;
esac

printf '%s\n' '--- steer contract facts ---'
out="$(run_uc '
let e = require("core.engine");
print("spec=" + e.STEER_SPEC_FILE + "\n");
print("state=" + e.STEER_STATE_DIR + "\n");
print("table=" + e.STEER_NFT_TABLE + "\n");
print("zdir=" + e.STEER_ZAPRET_DIR + "\n");
print("cmds=" + length(e.STEER_REQUIRED_COMMANDS) + "\n");
print("keep=" + length(e.STEER_KEEP_PATHS) + "\n");
print("ready=" + e.steer_contract_ready() + "\n");
')"
assert_match "steer spec path" 'spec=/etc/steer/spec.json' "$out"
assert_match "steer state dir" 'state=/var/lib/steer' "$out"
assert_match "steer nft table isolated" 'table=inet steer' "$out"
assert_match "steer zapret opts dir" 'zdir=/etc/steer/zapret' "$out"
assert_match "steer contract commands listed" 'cmds=7' "$out"
assert_match "steer keep paths listed" 'keep=5' "$out"
assert_match "contract not ready without engine" 'ready=false' "$out"

printf '%s\n' '--- CLI info surface ---'
out="$($TACHYON_UCODE -L "$TACHYON_LIB" "$TACHYON_LIB/service/engine_runtime.uc" engine-info 2>&1)"
assert_match "engine-info reports active engine" '"active": *"sing-box"' "$out"
assert_match "engine-info lists engines" '"engine": *"steer"' "$out"

out="$($TACHYON_UCODE -L "$TACHYON_LIB" "$TACHYON_LIB/service/engine_runtime.uc" engine-plan steer 2>&1)"
assert_match "engine-plan targets steer" '"to_engine": *"steer"' "$out"

out="$($TACHYON_UCODE -L "$TACHYON_LIB" "$TACHYON_LIB/service/engine_runtime.uc" engine-diag 2>&1 || true)"
assert_match "engine-diag refuses without engine" 'engine_not_installed|not installed|No such file' "$out"

printf '%s\n' '--- switch refuses when engine is not installed ---'
out="$(TACHYON_UCI_STATE_FILE="$WORK_DIR/uci3.state" run_uc '
let s = require("components.engine_state");
let result = s.apply_switch("steer", {});
print("ok=" + result.ok + "\n");
print("reason=" + result.reason + "\n");
print("installable=" + result.installable + "\n");
')"
assert_match "switch refused" 'ok=false' "$out"
assert_match "reason is engine_not_installed" 'reason=engine_not_installed' "$out"
assert_match "switch offers install" 'installable=true' "$out"

printf '%s\n' '--- switch with allow-install parks and flips ---'
out="$(TACHYON_UCI_STATE_FILE="$WORK_DIR/uci4.state" run_uc '
let s = require("components.engine_state");
let e = require("core.engine");
let result = s.apply_switch("steer", { allow_install: true });
print("ok=" + result.ok + "\n");
print("from=" + result.from_engine + "\n");
print("to=" + result.to_engine + "\n");
print("active=" + e.get_active() + "\n");
print("previous=" + e.get_previous() + "\n");
')"
assert_match "switch succeeds with allow-install" 'ok=true' "$out"
assert_match "switch records from engine" 'from=sing-box' "$out"
assert_match "switch records to engine" 'to=steer' "$out"
assert_match "active engine flipped" 'active=steer' "$out"
assert_match "previous engine recorded" 'previous=sing-box' "$out"

printf '%s\n' '--- switch back restores previous ---'
out="$(TACHYON_UCI_STATE_FILE="$WORK_DIR/uci5.state" run_uc '
let s = require("components.engine_state");
let e = require("core.engine");
s.apply_switch("steer", { allow_install: true });
let back = s.switch_back({ allow_install: true });
print("ok=" + back.ok + "\n");
print("active=" + e.get_active() + "\n");
print("previous=" + e.get_previous() + "\n");
')"
assert_match "switch back succeeds" 'ok=true' "$out"
assert_match "active engine restored" 'active=sing-box' "$out"
assert_match "previous now points at steer" 'previous=steer' "$out"

printf '%s\n' '--- switch back without previous is refused ---'
out="$(TACHYON_UCI_STATE_FILE="$WORK_DIR/uci6.state" run_uc '
let s = require("components.engine_state");
let result = s.switch_back({});
print("ok=" + result.ok + "\n");
print("reason=" + result.reason + "\n");
')"
assert_match "switch back refused" 'ok=false' "$out"
assert_match "no previous engine reported" 'reason=no_previous_engine' "$out"

printf '%s\n' '--- lifecycle engine branches ---'
LIFECYCLE_UC="$TACHYON_LIB/service/lifecycle.uc"
grep -Fq 'start_steer_main' "$LIFECYCLE_UC" ||
    fail_test "lifecycle must have a steer start branch"
grep -Fq 'reload_steer' "$LIFECYCLE_UC" ||
    fail_test "lifecycle must have a steer reload branch"
grep -Fq 'get_active()' "$LIFECYCLE_UC" ||
    fail_test "lifecycle must consult the active engine"
# The steer branches must not run the sing-box start pipeline.
steer_branch="$(sed -n '/^function start_steer_main/,/^}/p' "$LIFECYCLE_UC")"
grep -Fq 'generate_steer_spec' <<<"$steer_branch" ||
    fail_test "steer start must generate the spec"
if grep -Fq 'nft_rebuild_runtime' <<<"$steer_branch"; then
    fail_test "steer start must not run the sing-box nft pipeline"
fi
reload_branch="$(sed -n '/^function reload_steer/,/^}/p' "$LIFECYCLE_UC")"
grep -Fq 'generate_steer_spec' <<<"$reload_branch" ||
    fail_test "steer reload must regenerate the spec"
pass=$((pass + 1))

printf '%s\n' '--- sing-box-only start work must not run on steer ---'
# The engine branch must come before the sing-box config validator: the
# validator would abort the start on a steer-only device.
start_main_body="$(sed -n '/^function start_main/,/^}/p' "$LIFECYCLE_UC")"
validator_line="$(grep -n 'validate_start_config' <<<"$start_main_body" | head -1 | cut -d: -f1)"
engine_branch_line="$(grep -n 'active_engine_is_steer' <<<"$start_main_body" | head -1 | cut -d: -f1)"
if [ -z "$validator_line" ] || [ -z "$engine_branch_line" ]; then
    fail_test "start_main must call validate_start_config and check the engine"
elif [ "$engine_branch_line" -ge "$validator_line" ]; then
    fail_test "engine branch must be checked before the sing-box validator"
fi
pass=$((pass + 1))
# On steer dnsmasq must be restored, never configured for the sing-box DNS.
start_impl_body="$(sed -n '/^function start_impl/,/^}/p' "$LIFECYCLE_UC")"
grep -Fq 'active_engine_is_steer' <<<"$start_impl_body" ||
    fail_test "start_impl must branch dnsmasq handling per engine"
pass=$((pass + 1))

printf '%s\n' '--- switch goes through the full lifecycle ---'
# switch_engine must restart the service (lifecycle handles the dataplane
# cleanup, spec generation and per-engine start), not stop/start engines inline.
ENGINE_RUNTIME_UC="$TACHYON_LIB/service/engine_runtime.uc"
switch_body="$(sed -n '/^function switch_engine/,/^}/p' "$ENGINE_RUNTIME_UC")"
grep -Fq 'restart_tachyon_service' <<<"$switch_body" ||
    fail_test "switch_engine must restart the service via the lifecycle"
grep -Fq 'start_failed_rolled_back' <<<"$switch_body" ||
    fail_test "switch_engine must roll the config back when the restart fails"
if grep -Eq 'stop_other_engines|run_init' <<<"$switch_body"; then
    fail_test "switch_engine must not stop/start engines inline"
fi
restart_fn="$(sed -n '/^function restart_tachyon_service/,/^}/p' "$ENGINE_RUNTIME_UC")"
grep -Fq '"restart"' <<<"$restart_fn" ||
    fail_test "restart_tachyon_service must call the init script restart"
pass=$((pass + 1))

printf '%s\n' '--- engine status is engine-aware ---'
RUNTIME_UC="$TACHYON_LIB/diagnostics/runtime.uc"
grep -Fq 'function get_engine_status' "$RUNTIME_UC" ||
    fail_test "diagnostics/runtime.uc must define get_engine_status"
grep -Fq 'get-engine-status' "$RUNTIME_UC" ||
    fail_test "diagnostics/runtime.uc must dispatch get-engine-status"
grep -Fq 'get_engine_status:' "$TACHYON_BIN" ||
    fail_test "tachyon entrypoint must expose get_engine_status"
# steer uses START=94: a hardcoded S99steer check always reports stopped.
if grep -Fq 'S99steer' "$RUNTIME_UC"; then
    fail_test "get_engine_status must not hardcode S99steer (steer is START=94)"
fi
grep -Fq 'rc.d/S*steer' "$RUNTIME_UC" ||
    fail_test "get_engine_status must detect the steer enable symlink"
pass=$((pass + 1))

printf '%s\n' '--- restart and reload lifecycle steer guards ---'
restart_body="$(sed -n '/^function restart(/,/^}/p' "$LIFECYCLE_UC")"
grep -Fq 'active_engine_is_steer' <<<"$restart_body" ||
    fail_test "restart() must check active_engine_is_steer"
restart_sb_wait="$(grep -n 'wait-sing-box-service-stable' <<<"$restart_body" | head -1 | cut -d: -f1)"
restart_steer_guard="$(grep -n 'active_engine_is_steer' <<<"$restart_body" | head -1 | cut -d: -f1)"
if [ -z "$restart_sb_wait" ] || [ -z "$restart_steer_guard" ]; then
    fail_test "restart must have steer guard and sing-box wait"
elif [ "$restart_steer_guard" -ge "$restart_sb_wait" ]; then
    fail_test "restart must guard against waiting for sing-box when steer is active"
fi

reload_restart_body="$(sed -n '/^function restart_runtime_for_reload/,/^}/p' "$LIFECYCLE_UC")"
grep -Fq 'active_engine_is_steer' <<<"$reload_restart_body" ||
    fail_test "restart_runtime_for_reload() must check active_engine_is_steer"

stop_main_body="$(sed -n '/^function stop_main/,/^}/p' "$LIFECYCLE_UC")"
grep -Fq '/etc/init.d/steer' <<<"$stop_main_body" ||
    fail_test "stop_main must stop steer service"

UI_UC="$TACHYON_LIB/service/ui.uc"
ui_running_body="$(sed -n '/^function tachyon_running/,/^}/p' "$UI_UC")"
grep -Fq 'active_engine != "sing-box"' <<<"$ui_running_body" ||
    fail_test "ui.uc tachyon_running must be engine-aware"

EVENT_CTRL_UC="$TACHYON_LIB/service/event_controller.uc"
probe_sb_body="$(sed -n '/^    function probe_singbox/,/^    }/p' "$EVENT_CTRL_UC")"
grep -Fq 'active_engine != "sing-box"' <<<"$probe_sb_body" ||
    fail_test "event_controller probe_singbox must be engine-aware"
pass=$((pass + 1))

printf '\n--- engine_orchestrator.sh summary ---\n'
printf 'passed: %d\n' "$pass"
printf 'failed: %d\n' "$fail"

if [ "$fail" -gt 0 ]; then
    printf '%s\n' '--- FAIL ---'
    exit 1
fi

printf '%s\n' '--- PASS ---'
exit 0
