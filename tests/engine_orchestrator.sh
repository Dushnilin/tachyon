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
    if echo "$actual" | grep -qE "$pattern"; then
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
assert_match "spec schema 1" 'schema=1' "$out"
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

printf '%s\n' '--- steer contract facts ---'
out="$(run_uc '
let e = require("core.engine");
print("spec=" + e.STEER_SPEC_FILE + "\n");
print("state=" + e.STEER_STATE_DIR + "\n");
print("table=" + e.STEER_NFT_TABLE + "\n");
print("cmds=" + length(e.STEER_REQUIRED_COMMANDS) + "\n");
print("keep=" + length(e.STEER_KEEP_PATHS) + "\n");
print("ready=" + e.steer_contract_ready() + "\n");
')"
assert_match "steer spec path" 'spec=/etc/steer/spec.json' "$out"
assert_match "steer state dir" 'state=/var/lib/steer' "$out"
assert_match "steer nft table isolated" 'table=inet steer' "$out"
assert_match "steer contract commands listed" 'cmds=7' "$out"
assert_match "steer keep paths listed" 'keep=4' "$out"
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

printf '%s\n' '--- engine status is engine-aware ---'
RUNTIME_UC="$TACHYON_LIB/diagnostics/runtime.uc"
grep -Fq 'function get_engine_status' "$RUNTIME_UC" ||
    fail_test "diagnostics/runtime.uc must define get_engine_status"
grep -Fq 'get-engine-status' "$RUNTIME_UC" ||
    fail_test "diagnostics/runtime.uc must dispatch get-engine-status"
grep -Fq 'get_engine_status:' "$TACHYON_BIN" ||
    fail_test "tachyon entrypoint must expose get_engine_status"
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
