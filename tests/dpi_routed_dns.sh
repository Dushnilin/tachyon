#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"
STATE_UC="$TACHYON_LIB/service/state.uc"

# A routed resolver must resolve the upstream destination without replacing the
# client's FakeIP: otherwise domain-only traffic never enters the TPROXY rules.
for version in 0.5.7; do
  printf '%s\n' "$version" >"$WORK_DIR/version"
  for action in desync; do
    fixture="$WORK_DIR/$version-$action.json"
    output="$WORK_DIR/$version-$action-out.json"
    ucode -e '
      let action = ARGV[0];
      print(sprintf("%J\n", {
        settings: { ".name": "settings", ".type": "settings", enabled: "1", dns_type: "udp", dns_server: "1.1.1.1", service_listen_address: "127.0.0.1", ipv6_mode: "dual_stack" },
        section: [
          { ".name": "dpi", ".type": "section", enabled: "1", action,
            domain_suffix: [ "dpi.example" ], community_lists: [ "youtube" ],
            routed_dns_enabled: "1", routed_dns_type: "doh", routed_dns_server: "https://1.1.1.1/dns-query" },
          { ".name": "bypass", ".type": "section", enabled: "1", action: "bypass",
            domain_suffix: [ "direct.example" ], routed_dns_enabled: "1", routed_dns_type: "udp", routed_dns_server: "9.9.9.9" }
        ]
      }));
    ' "$action" >"$fixture"
    mkdir -p "$output.section-cache" "$output.rulesets"
    TACHYON_CORE_VERSION_FILE="$WORK_DIR/version" \
      ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture "$fixture" "$output" 127.0.0.1 0 1
    ucode -e '
      let cfg = json(require("fs").readfile(ARGV[0]));
      let fake_domain = -1, routed_domain = -1, fake_list = -1, routed_list = -1;
      let bypass_ok = false, routed_resolve = false, detour_ok = false;
      for (let i, r in cfg.dns.rules) {
        let domain = index(sprintf("%J", r.domain_suffix), "dpi.example") >= 0;
        let list = index(sprintf("%J", r.rule_set), "youtube") >= 0;
        if ((domain || list) && r.server == "fakeip-server") {
          if (length(r.query_type) != 2 || r.query_type[0] != "A" || r.query_type[1] != "AAAA")
            die("DPI FakeIP must only answer A/AAAA\n");
          if (domain) fake_domain = i;
          if (list) fake_list = i;
        }
        if ((domain || list) && r.server == "dpi-routed-dns-server") {
          if (r.query_type != null) die("routed DNS fallback must retain other query types\n");
          if (domain) routed_domain = i;
          if (list) routed_list = i;
        }
        if (index(sprintf("%J", r.domain_suffix), "direct.example") >= 0) {
          if (r.server == "fakeip-server") die("bypass DNS must keep real addresses\n");
          bypass_ok = r.server == "bypass-routed-dns-server";
        }
      }
      for (let r in cfg.route.rules)
        if (r.action == "resolve" && r.server == "dpi-routed-dns-server") routed_resolve = true;
      for (let s in cfg.dns.servers)
        if (s.tag == "dpi-routed-dns-server" && s.detour != null) detour_ok = true;
      if (fake_domain < 0 || routed_domain <= fake_domain) die("DPI domain must receive FakeIP before routed DNS fallback\n");
      if (fake_list < 0 || routed_list <= fake_list) die("DPI ruleset must receive FakeIP before routed DNS fallback\n");
      if (!routed_resolve || !detour_ok || !bypass_ok) die("routed resolver, detour or bypass behavior changed\n");
    ' "$output" || fail "$action routed DNS / FakeIP on $version"
  done
done

# Keep client restrictions and exclusions on both halves of the DNS rule.
scoped="$WORK_DIR/scoped.json"
ucode -e '
  let cfg = json(require("fs").readfile(ARGV[0]));
  cfg.section[0].source_ip_cidr = [ "192.0.2.0/24" ];
  cfg.section[0].excluded_ips = [ "192.0.2.42" ];
  cfg.section[0].ipv6_support = "0";
  print(sprintf("%J\n", cfg));
' "$WORK_DIR/0.5.7-desync.json" >"$scoped"
mkdir -p "$scoped.out.section-cache" "$scoped.out.rulesets"
TACHYON_CORE_VERSION_FILE="$WORK_DIR/version" \
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture "$scoped" "$scoped.out" 127.0.0.1 0 1
ucode -e '
  let cfg = json(require("fs").readfile(ARGV[0]));
  let fake = false, fallback = false;
  for (let r in cfg.dns.rules) {
    if (index(sprintf("%J", r), "dpi.example") < 0) continue;
    if (r.server != "fakeip-server" && r.server != "dpi-routed-dns-server") continue;
    if (r.type != "logical" || r.mode != "and") die("DNS source exclusion lost\n");
    let source = false, excluded = false;
    for (let part in r.rules) {
      if (!part.invert && index(sprintf("%J", part.source_ip_cidr), "192.0.2.0/24") >= 0) {
        source = true;
        if (r.server == "fakeip-server" && (length(part.query_type) != 1 || part.query_type[0] != "A"))
          die("IPv4-only DPI must not synthesize AAAA\n");
      }
      if (part.invert && index(sprintf("%J", part.source_ip_cidr), "192.0.2.42") >= 0) excluded = true;
    }
    if (!source || !excluded) die("DNS client restriction or exclusion lost\n");
    if (r.server == "fakeip-server") fake = true;
    else fallback = true;
  }
  if (!fake || !fallback) die("scoped DNS rules missing\n");
' "$scoped.out" || fail "source-scoped IPv4-only routed DPI DNS"

# These fields change generated DNS servers/rules, so reload must rebuild the
# core config as well as nftables. Previously only the nft signature changed.
base="$WORK_DIR/0.5.7-desync.json"
base_signature="$(ucode -L "$TACHYON_LIB" "$STATE_UC" tachyon-core-signature-fixture "$base")"
for option in routed_dns_enabled routed_dns_type routed_dns_server; do
  candidate="$WORK_DIR/$option.json"
  ucode -e '
    let cfg = json(require("fs").readfile(ARGV[0]));
    let values = { routed_dns_enabled: "0", routed_dns_type: "dot", routed_dns_server: "9.9.9.9" };
    cfg.section[0][ARGV[1]] = values[ARGV[1]];
    print(sprintf("%J\n", cfg));
  ' "$base" "$option" >"$candidate"
  next_signature="$(ucode -L "$TACHYON_LIB" "$STATE_UC" tachyon-core-signature-fixture "$candidate")"
  [ "$base_signature" != "$next_signature" ] || fail "$option must invalidate the core reload signature"
done

# A closed GeoIP mode needs the real address: the country of the destination
# is decided before the outbound is chosen, and a FakeIP address has none.
# So the domain rule must not be replaced by FakeIP there.
for mode in include_all exclude_direct; do
  closed="$WORK_DIR/geo-0.5.7-desync-$mode.json"
  ucode -e '
    let cfg = json(require("fs").readfile(ARGV[0]));
    cfg.section[0].geoip_mode = ARGV[1];
    print(sprintf("%J\n", cfg));
  ' "$base" "$mode" >"$closed"
  mkdir -p "$closed.out.section-cache" "$closed.out.rulesets"
  TACHYON_CORE_VERSION_FILE="$WORK_DIR/version" \
    ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture "$closed" "$closed.out" 127.0.0.1 0 1
  ucode -e '
    let cfg = json(require("fs").readfile(ARGV[0]));
    for (let r in cfg.dns.rules) {
      if (index(sprintf("%J", r.domain_suffix), "dpi.example") < 0) continue;
      if (r.server == "fakeip-server")
        die("a closed geoip mode must keep the real address\n");
    }
  ' "$closed.out" || fail "closed geoip mode ($mode) must not receive FakeIP"
done

# A ruleset that matches addresses as well as domains may not produce FakeIP:
# the match would lose the real destination, and the DPI rule that follows
# could not match it. The real answer has to stay.
mixed="$WORK_DIR/mixed.json"
ucode -e '
  let cfg = json(require("fs").readfile(ARGV[0]));
  cfg.section[0].community_lists = [ "youtube", "telegram" ];
  print(sprintf("%J\n", cfg));
' "$base" >"$mixed"
mkdir -p "$mixed.out.section-cache" "$mixed.out.rulesets"
TACHYON_CORE_VERSION_FILE="$WORK_DIR/version" \
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture "$mixed" "$mixed.out" 127.0.0.1 0 1
ucode -e '
  let cfg = json(require("fs").readfile(ARGV[0]));
  let mixed_real = false;
  for (let r in cfg.dns.rules) {
    let is_mixed = index(sprintf("%J", r.rule_set), "telegram") >= 0;
    if (!is_mixed) continue;
    if (r.server == "fakeip-server")
      die("a ruleset that matches addresses must not be replaced by FakeIP\n");
    if (r.server == "dpi-routed-dns-server") mixed_real = true;
  }
  if (!mixed_real) die("the mixed ruleset must keep the real answer\n");
' "$mixed.out" || fail "an address-matching ruleset must keep the real DNS answer"

# The real-engine check: it runs the generated config through a live core and
# watches the answers. It needs a core binary, so it only runs when one is
# given.
if [ -n "${TACHYON_CORE_RUNTIME_BIN:-}" ]; then
  python3 "$ROOT_DIR/tests/lib/dpi_routed_dns_runtime.py" \
    "$TACHYON_CORE_RUNTIME_BIN" "$WORK_DIR/0.5.7-desync-out.json"
  for mode in exclude_direct include_all; do
    python3 "$ROOT_DIR/tests/lib/dpi_routed_dns_runtime.py" \
      "$TACHYON_CORE_RUNTIME_BIN" "$WORK_DIR/geo-0.5.7-desync-$mode-out.json" --geoip-mode "$mode"
  done
fi

# Issue #486: routed_dns_use_global inherits global DNS servers and encrypted/UDP
# fallbacks automatically, keeps section-local detour (no VPN detour leakage),
# passes validation without routed_dns_server, and updates core signature.
global_routed="$WORK_DIR/global-routed-desync.json"
cat >"$global_routed" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_type": "doh",
    "dns_server": [ "1.1.1.1/dns-query", "dns.google/dns-query" ],
    "dns_fallback_server": [ "8.8.4.4", "9.9.9.9" ],
    "bootstrap_dns_server": [ "77.88.8.8" ],
    "dns_detour_enabled": "1",
    "dns_detour_section": "vpn",
    "fakeip": "1",
    "ipv6_mode": "ipv4_only"
  },
  "section": [
    {
      ".name": "dpi",
      ".type": "section",
      "enabled": "1",
      "action": "desync",
      "desync_preset": "auto",
      "domain_suffix": [ "youtube.com" ],
      "routed_dns_enabled": "1",
      "routed_dns_use_global": "1"
    },
    {
      ".name": "vpn",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [ "socks5://127.0.0.1:1081#VpnNode" ],
      "domain_suffix": [ "blocked.example" ]
    }
  ]
}
JSON

VALIDATOR_UC="$TACHYON_LIB/config/validator.uc"
if ! val_out="$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-fixture "$global_routed" "{}" 2>&1)"; then
  fail "validator must accept routed_dns_use_global=1 without routed_dns_server: $val_out"
fi

global_routed_missing_manual="$WORK_DIR/global-routed-missing-manual.json"
ucode -e '
  let d = json(require("fs").readfile(ARGV[0]));
  d.section[0].routed_dns_use_global = "0";
  print(sprintf("%J\n", d));
' "$global_routed" >"$global_routed_missing_manual"
if TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-fixture "$global_routed_missing_manual" "{}" >/dev/null 2>&1; then
  fail "validator must still reject routed_dns_enabled=1 when routed_dns_use_global=0 and routed_dns_server is empty"
fi

mkdir -p "$global_routed.out.section-cache" "$global_routed.out.rulesets"
TACHYON_CORE_VERSION_FILE="$WORK_DIR/version" \
  TACHYON_DNS_FAILOVER_STATE_FILE="$WORK_DIR/missing-global-failover.json" \
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture "$global_routed" "$global_routed.out" 127.0.0.1 0 1

ucode -e '
  let cfg = json(require("fs").readfile(ARGV[0]));
  let grp = null;
  let members = {};
  for (let s in cfg.dns.servers || []) {
    if (s.tag == "dpi-routed-dns-server") grp = s;
    members[s.tag] = s;
  }
  if (!grp || grp.type != "group" || length(grp.servers || []) != 2)
    die("#486: dpi-routed-dns-server must be a group with 2 inherited DoH primary servers: " + sprintf("%J", grp) + "\n");
  for (let tag in grp.servers) {
    let m = members[tag];
    if (!m || m.type != "https")
      die("#486: inherited global encrypted member must be https (no plain UDP leak): " + sprintf("%J", m) + "\n");
    if (m.detour != "dpi-out")
      die("#486: desync routed DNS must keep section detour dpi-out (not vpn-out): " + sprintf("%J", m) + "\n");
  }
  let has_resolve = false;
  for (let r in cfg.route.rules || []) {
    if (r.action == "resolve" && r.server == "dpi-routed-dns-server")
      has_resolve = true;
  }
  if (!has_resolve)
    die("#486: route.rules must resolve desync traffic via dpi-routed-dns-server\n");
' "$global_routed.out" || fail "#486 routed_dns_use_global with global DoH in desync section"

global_routed_udp="$WORK_DIR/global-routed-udp.json"
ucode -e '
  let d = json(require("fs").readfile(ARGV[0]));
  d.settings.dns_type = "udp";
  d.settings.dns_server = [ "77.88.8.8" ];
  print(sprintf("%J\n", d));
' "$global_routed" >"$global_routed_udp"
mkdir -p "$global_routed_udp.out.section-cache" "$global_routed_udp.out.rulesets"
TACHYON_CORE_VERSION_FILE="$WORK_DIR/version" \
  TACHYON_DNS_FAILOVER_STATE_FILE="$WORK_DIR/missing-global-udp-failover.json" \
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture "$global_routed_udp" "$global_routed_udp.out" 127.0.0.1 0 1
ucode -e '
  let cfg = json(require("fs").readfile(ARGV[0]));
  let grp = null;
  let hosts = [];
  let members = {};
  for (let s in cfg.dns.servers || []) {
    if (s.tag == "dpi-routed-dns-server") grp = s;
    members[s.tag] = s;
  }
  if (!grp || grp.type != "group" || length(grp.servers || []) != 3)
    die("#486 udp: dpi-routed-dns-server must inherit main+fallbacks+bootstrap when global DNS is UDP: " + sprintf("%J", grp) + "\n");
  for (let tag in grp.servers) {
    let m = members[tag];
    if (!m || m.type != "udp" || m.detour != "dpi-out")
      die("#486 udp: inherited member must be udp with dpi-out detour: " + sprintf("%J", m) + "\n");
    push(hosts, m.server);
  }
  for (let expected in [ "77.88.8.8", "8.8.4.4", "9.9.9.9" ]) {
    if (index(hosts, expected) < 0)
      die("#486 udp: missing inherited server " + expected + " in " + sprintf("%J", hosts) + "\n");
  }
' "$global_routed_udp.out" || fail "#486 routed_dns_use_global with global UDP + fallbacks"

sig_global_on="$(ucode -L "$TACHYON_LIB" "$STATE_UC" tachyon-core-signature-fixture "$global_routed")"
global_routed_off="$WORK_DIR/global-routed-off.json"
ucode -e '
  let d = json(require("fs").readfile(ARGV[0]));
  d.section[0].routed_dns_use_global = "0";
  d.section[0].routed_dns_type = "doh";
  d.section[0].routed_dns_server = [ "https://9.9.9.9/dns-query" ];
  print(sprintf("%J\n", d));
' "$global_routed" >"$global_routed_off"
sig_global_off="$(ucode -L "$TACHYON_LIB" "$STATE_UC" tachyon-core-signature-fixture "$global_routed_off")"
[ "$sig_global_on" != "$sig_global_off" ] || fail "#486 toggling routed_dns_use_global must invalidate core reload signature"

printf 'DPI routed DNS preserves FakeIP interception and invalidates core reload state\n'
