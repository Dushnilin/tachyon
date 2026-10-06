#!/usr/bin/env bash
# Spec v2 shape of the steer generator.
#
# v2 is a different document from the contract-v1 output, recognised by a
# top-level `version: 2`. These assertions pin the v2 shape and, just as
# important, pin the absence of every v1-only key - an unknown key is a hard
# rejection in steer, so a leftover one takes the whole spec down.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# The generator is a library module with no CLI. It is driven from a script
# file rather than `ucode -e`: driving it through `-e` aborts the ucode process
# (SIGSEGV / "double free") on multi-section fixtures, while the same call from a
# script file is fine. That crash is unresolved and predates the v2 work, but it
# is not this test's subject - use the file form and stay alive.
cat >"$WORK_DIR/driver.uc" <<'EOF'
let fs = require("fs");
let gen = require("steer.generator");
let as_string = require("core.common").as_string;

gen.set_vless_supported(true);
gen.set_list_materializer(function(section, _catalog) {
  if (as_string(section[".name"]) == "rule_domains")
    return { domains: "/etc/steer/lists/blocked.dom", prefixes: null };
  return { domains: null, prefixes: null };
});

let data = json(fs.readfile(ARGV[0]));
print(sprintf("%J", gen[ARGV[1]](data.section, data.settings, {})));
EOF

build_v2() {
  ucode -L "$TACHYON_LIB" "$WORK_DIR/driver.uc" "$1" build_spec_v2 2>/dev/null
}

cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_redirect": "1",
    "source_network_interfaces": [ "br-lan" ]
  },
  "section": [
    {
      ".name": "wg_single",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "label": "WG Single",
      "outbound_interface": "wg0"
    },
    {
      ".name": "wg_multi",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "label": "WG Multi",
      "outbound_interfaces": [ "wg1", "wg2" ]
    },
    {
      ".name": "sub_auto",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "label": "Sub Auto",
      "steer_sub_file": "/etc/steer/subs/sub_auto.txt",
      "node": "auto"
    },
    {
      ".name": "sub_fixed",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "label": "Sub Fixed",
      "steer_sub_file": "/etc/steer/subs/sub_fixed.txt",
      "node": "2"
    },
    {
      ".name": "rule_domains",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound": "WG Single",
      "domain_list_files": [ "/etc/steer/lists/blocked.dom" ]
    },
    {
      ".name": "rule_clients",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "label": "Rule Clients",
      "outbound": "WG Single",
      "client_addresses": [ "192.168.1.50" ],
      "mac_addresses": [ "aa:bb:cc:dd:ee:01" ]
    }
  ]
}
JSON

spec="$(build_v2 "$WORK_DIR/fixture.json")"
[ -n "$spec" ] || fail "build_spec_v2 produced no output"
flat="$(printf '%s' "$spec" | tr -d ' \t\r\n')"

# ─── the format marker, and v1's marker must be gone ─────────────────────────
case "$flat" in
  *'"version":2'*) : ;;
  *) fail "v2 spec must be identified by a top-level version: 2, got: $flat";;
esac
case "$flat" in
  *'"schema"'*)
    fail "version and schema together is a rejection in steer, got: $flat";;
esac

# ─── every v1-only key must be absent ────────────────────────────────────────
for legacy in '"schema":' '"channels":' '"lan_devices":' '"dns_redirect":' \
               '"sub_file":' '"opts_file":' '"nfqws_bin":' \
               '"prefer":' '"latency_interval_s":' '"latency_tolerance_ms":' \
               '"match":' '"from":' '"domains_files":' '"prefixes_files":'; do
  case "$flat" in
    *"$legacy"*)
      fail "v2 spec must not contain the v1-only key $legacy, got: $flat";;
  esac
done
# `devices` is a legitimate v2 key on lan; what must be gone is the v1 plural
# form on an interface output, where v2 takes a single device.
case "$flat" in
  *'"kind":"interface","devices"'*)
    fail "an interface output must carry a single device, not the v1 devices list, got: $flat";;
esac
case "$flat" in
  *'"node":'*)
    fail "the v1 scalar node key must be gone, v2 only has the nodes list, got: $flat";;
esac
printf '  ok: no v1-only keys survive\n'

# ─── v2 sections ────────────────────────────────────────────────────────────
for section_key in '"lan":' '"lists":' '"outputs":' '"rules":' '"dns":'; do
  case "$flat" in
    *"$section_key"*) : ;;
    *) fail "v2 spec is missing the $section_key section, got: $flat";;
  esac
done
case "$flat" in
  *'"lan":{"devices":["br-lan"]}'*) : ;;
  *) fail "lan_devices must become lan.devices, got: $flat";;
esac
printf '  ok: v2 sections present and lan uses devices\n'

# ─── interface takes one device; several become a group ──────────────────────
case "$flat" in
  *'"WG_Single":{"kind":"interface","device":"wg0"'*) : ;;
  *) fail "a single interface device must be kind: interface with device, got: $flat";;
esac
case "$flat" in
  *'"WG_Multi":{"kind":"group","pick":"order","members":["WG_Multi-1","WG_Multi-2"]'*) : ;;
  *) fail "several devices must become a group with pick: order, got: $flat";;
esac
case "$flat" in
  *'"WG_Multi-1":{"kind":"interface","device":"wg1"'*) : ;;
  *'"WG_Multi-2":{"kind":"interface","device":"wg2"'*) : ;;
  *) fail "each device needs its own interface output, got: $flat";;
esac
printf '  ok: multi-device section became an order group over per-device outputs\n'

# ─── vless: kind tunnel + protocol, and auto-select split into a group ────────
case "$flat" in
  *'"kind":"tunnel","protocol":"vless","subscription":'*) : ;;
  *) fail "vless must become kind: tunnel with protocol: vless and subscription, got: $flat";;
esac
case "$flat" in
  *'"Sub_Auto":{"kind":"group","pick":"latency","members":["Sub_Auto-tun"]'*) : ;;
  *) fail "an auto-selecting section must split into a group over its tunnel, got: $flat";;
esac
case "$flat" in
  *'"Sub_Auto-tun":{"kind":"tunnel"'*) : ;;
  *) fail "the split must leave the tunnel output itself, got: $flat";;
esac
case "$flat" in
  *'"Sub_Fixed"'*'"nodes":[2]'*) : ;;
  *) fail "a pinned node must become nodes: [N], got: $flat";;
esac
printf '  ok: tunnel + group split, and pinned node uses nodes\n'

# ─── rules reference a named list through `to`, not inline files ─────────────
case "$flat" in
  *'"lists":{"rule_domains":{"domains_file":["/etc/steer/lists/blocked.dom"]}'*) : ;;
  *) fail "list files must move into a named lists section, got: $flat";;
esac
case "$flat" in
  *'"rules":'*) : ;;
  *) fail "channels must become rules, got: $flat";;
esac
case "$flat" in
  *'"to":["rule_domains"]'*) : ;;
  *) fail "a rule must reference its list by name through to, got: $flat";;
esac
printf '  ok: rules reference a named list\n'

# ─── rules.for is names from `clients`, not inline addresses ──────────────────
# The one that is easy to get wrong: v1 inlined raw addresses and MACs into the
# channel, and v2 kept the key name `for` while changing what it holds. Writing
# an address where a name belongs is a dangling reference and steer rejects the
# whole spec over it, so it needs an assertion of its own.
case "$flat" in
  *'"clients":{"rule_clients":{"addr":["192.168.1.50"]}'*) : ;;
  *) fail "client filters must move into a top-level clients section, got: $flat";;
esac
case "$flat" in
  *'"for":["rule_clients"]'*) : ;;
  *) fail "a rule must reference its client by name through for, got: $flat";;
esac
case "$flat" in
  *'"for":["192.168.1.50"]'*|*'"for":["aa:bb:cc:dd:ee:01"]'*)
    fail "rules.for holds client names in v2; a raw address or MAC there is a dangling reference, got: $flat";;
esac
# addr and mac cannot share one client - nft has no "or" inside a rule.
case "$flat" in
  *'"rule_clients":{"addr":["192.168.1.50"]}'*|*'"rule_clients-mac":{"mac":["aa:bb:cc:dd:ee:01"]}'*) : ;;
  *) fail "addr and mac must not share one client, and both must be emitted, got: $flat";;
esac
case "$flat" in
  *'"for":["rule_clients-mac"]'*) : ;;
  *) fail "a MAC filter needs its own client and rule, got: $flat";;
esac
printf '  ok: rules reference clients by name\n'

# ─── dns.mode replaces dns_redirect ─────────────────────────────────────────
case "$flat" in
  *'"dns":{"mode":"fakeip"'*) : ;;
  *) fail "dns_redirect: 1 must become dns.mode: fakeip, got: $flat";;
esac

cat >"$WORK_DIR/realip.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_redirect": "0" },
  "section": []
}
JSON
realip="$(build_v2 "$WORK_DIR/realip.json" | tr -d ' \t\r\n')"
case "$realip" in
  *'"dns":{"mode":"realip"'*) : ;;
  *) fail "dns_redirect: 0 must become dns.mode: realip, got: $realip";;
esac
printf '  ok: dns.mode follows dns_redirect\n'

# ─── URLTest settings reach the latency group, in steer's units ───────────────
# UCI stores sing-box durations ("3m") where spec v2 wants plain seconds, and
# the four keys are legal only on `pick: latency`. Passing a duration through
# unchanged is not a different interval, it is a rejected spec.
cat >"$WORK_DIR/urltest.uc" <<'EOF'
let gen = require("steer.generator");
gen.set_vless_supported(true);
function group(settings) {
  let section = { ".name": "auto", "action": "connection", "enabled": "1", "label": "Auto",
                  "steer_sub_file": "/etc/steer/subs/a.txt", "node": "auto" };
  if (settings != null)
    section.steer_urltest_settings = [ settings ];
  print(sprintf("%J\n", gen.build_spec_v2([ section ], {}).outputs.Auto));
}
group({ check_interval: "3m", tolerance: "50",
        testing_url: "https://www.gstatic.com/generate_204", idle_timeout: "30m" });
group({ check_interval: "1s", tolerance: "99999", testing_url: "ftp://bad", idle_timeout: "500ms" });
group({ check_interval: "bogus", tolerance: "abc", testing_url: "http://x.example/g", idle_timeout: "" });
group(null);
EOF
ut="$(ucode -L "$TACHYON_LIB" "$WORK_DIR/urltest.uc" 2>&1 | tr -d ' \t\r\n')" \
  || fail "could not drive the latency group path: $ut"

case "$ut" in
  *'"tolerance":50,"interval":180,"idle_timeout":1800'*) : ;;
  *) fail "3m/50/30m must become interval:180, tolerance:50, idle_timeout:1800, got: $ut";;
esac
# Out-of-range values are clamped, never passed through: steer rejects interval
# below 5 s and tolerance above 60000.
case "$ut" in
  *'"tolerance":60000,"interval":5'*) : ;;
  *) fail "out-of-range interval/tolerance must be clamped into steer's limits, got: $ut";;
esac
# An ftp:// URL is not a check address, and 500ms has no honest conversion -
# both are dropped rather than guessed, so steer falls back to its own default.
case "$ut" in
  *'ftp://bad'*) fail "a non-http(s) testing_url was written into the spec, got: $ut";;
esac
case "$ut" in
  *'"idle_timeout":0'*|*'"tolerance":"NaN"'*|*'"interval":0'*)
    fail "an unconvertible value was written instead of being dropped, got: $ut";;
esac
# Only the two groups whose values were convertible carry the keys: the one with
# garbage in it and the one with no settings at all must fall back to steer
# defaults rather than invent numbers.
if [ "$(printf '%s' "$ut" | tr ',' '\n' | grep -c '"interval"')" != "2" ]; then
  fail "expected interval on exactly the two convertible groups, got: $ut"
fi
if [ "$(printf '%s' "$ut" | tr ',' '\n' | grep -c '"idle_timeout"')" != "1" ]; then
  fail "500ms has no conversion and an absent value must not be written, got: $ut"
fi
printf '  ok: urltest settings mapped into the latency group\n'

# ─── several urltest groups on one section are refused, not merged ───────────
# Spec v2 allows one latency group per output, so more than one urltest child is
# configuration this engine cannot honour. Taking the first silently would apply
# settings the user did not choose and drop the rest without a word.
cat >"$WORK_DIR/multigroup.uc" <<'EOF'
let gen = require("steer.generator");
gen.set_vless_supported(true);
let section = { ".name": "auto", "action": "connection", "enabled": "1", "label": "Auto",
                "steer_sub_file": "/etc/steer/subs/a.txt", "node": "auto" };
section.steer_urltest_settings = [
  { name: "Fastest", check_interval: "3m", tolerance: "10" },
  { name: "Cheapest", check_interval: "30m", tolerance: "900" }
];
print(sprintf("%J\n", gen.build_spec_v2([ section ], {}).outputs.Auto));
EOF
mg="$(ucode -L "$TACHYON_LIB" "$WORK_DIR/multigroup.uc" 2>&1)"
mg_group="$(printf '%s' "$mg" | grep -o '{.*}' | head -1)"
if printf '%s' "$mg_group" | grep -qE '"interval"|"tolerance"'; then
  fail "with two urltest groups the first one's settings were applied silently, got: $mg_group"
fi
printf '%s' "$mg" | grep -qi 'only one per section' \
  || fail "a section with more than one urltest group was neither honoured nor reported, got: $mg"
printf '  ok: ambiguous urltest groups refused and reported\n'

# ─── v1 is gone, not merely bypassed ─────────────────────────────────────────
# Only steer 2.0+ is supported now, so the contract-v1 builder has to be
# physically gone: left in place it would be one call site away from writing a
# `schema: 2` spec that a 2.x kernel either misreads or rejects.
for dead in 'function build_spec(' 'function build_outputs(' 'function build_channels(' 'SPEC_SCHEMA'; do
  if grep -RqF "$dead" "$TACHYON_LIB"; then
    fail "the contract-v1 builder ($dead) is still present; Tachyon no longer supports steer below 2.0"
  fi
done
# And nothing may still emit the v1 marker.
if grep -RqE '"schema"[[:space:]]*:|schema:[[:space:]]+SPEC' "$TACHYON_LIB/steer" "$TACHYON_LIB/service" 2>/dev/null; then
  fail "something still writes a \`schema:\` key, which marks the spec as v1"
fi
printf '  ok: v1 removed, only version: 2 is written\n'

printf 'steer spec v2 shape checks passed\n'
