#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"
STATE_UC="$TACHYON_LIB/service/state.uc"

# A routed resolver must resolve the upstream destination without replacing the
# client's FakeIP: otherwise domain-only traffic never enters the TPROXY rules.
for version in 1.13.5 1.14.1; do
  printf '%s\n' "$version" >"$WORK_DIR/version"
  for action in zapret zapret2 byedpi; do
    fixture="$WORK_DIR/$version-$action.json"
    output="$WORK_DIR/$version-$action-out.json"
    ucode -e '
      let action = ARGV[0];
      print(sprintf("%J\n", {
        settings: { ".name": "settings", ".type": "settings", enabled: "1", dns_type: "udp", dns_server: "1.1.1.1", service_listen_address: "127.0.0.1" },
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
    SB_VERSION_STATE_FILE="$WORK_DIR/version" \
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
  cfg.section[0].nfqws2_opt = "--filter-l3=ipv4 --filter-tcp=443";
  print(sprintf("%J\n", cfg));
' "$WORK_DIR/1.14.1-zapret2.json" >"$scoped"
mkdir -p "$scoped.out.section-cache" "$scoped.out.rulesets"
SB_VERSION_STATE_FILE="$WORK_DIR/version" \
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
base="$WORK_DIR/1.14.1-zapret2.json"
base_signature="$(ucode -L "$TACHYON_LIB" "$STATE_UC" sing-box-signature-fixture "$base")"
for option in routed_dns_enabled routed_dns_type routed_dns_server; do
  candidate="$WORK_DIR/$option.json"
  ucode -e '
    let cfg = json(require("fs").readfile(ARGV[0]));
    let values = { routed_dns_enabled: "0", routed_dns_type: "dot", routed_dns_server: "9.9.9.9" };
    cfg.section[0][ARGV[1]] = values[ARGV[1]];
    print(sprintf("%J\n", cfg));
  ' "$base" "$option" >"$candidate"
  next_signature="$(ucode -L "$TACHYON_LIB" "$STATE_UC" sing-box-signature-fixture "$candidate")"
  [ "$base_signature" != "$next_signature" ] || fail "$option must invalidate the core reload signature"
done

# A closed GeoIP mode needs the real address: the country of the destination
# is decided before the outbound is chosen, and a FakeIP address has none.
# So the domain rule must not be replaced by FakeIP there.
for mode in include_all exclude_direct; do
  closed="$WORK_DIR/geo-1.14.1-zapret2-$mode.json"
  ucode -e '
    let cfg = json(require("fs").readfile(ARGV[0]));
    cfg.section[0].geoip_mode = ARGV[1];
    print(sprintf("%J\n", cfg));
  ' "$base" "$mode" >"$closed"
  mkdir -p "$closed.out.section-cache" "$closed.out.rulesets"
  SB_VERSION_STATE_FILE="$WORK_DIR/version" \
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
SB_VERSION_STATE_FILE="$WORK_DIR/version" \
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
if [ -n "${SING_BOX_RUNTIME_BIN:-}" ]; then
  python3 "$ROOT_DIR/tests/lib/dpi_routed_dns_runtime.py" \
    "$SING_BOX_RUNTIME_BIN" "$WORK_DIR/1.14.1-zapret2-out.json"
  for mode in exclude_direct include_all; do
    python3 "$ROOT_DIR/tests/lib/dpi_routed_dns_runtime.py" \
      "$SING_BOX_RUNTIME_BIN" "$WORK_DIR/geo-1.14.1-zapret2-$mode-out.json" --geoip-mode "$mode"
  done
fi

printf 'DPI routed DNS preserves FakeIP interception and invalidates core reload state\n'
