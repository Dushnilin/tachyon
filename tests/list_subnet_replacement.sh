#!/usr/bin/env bash
# Real nft transactions in an isolated network namespace, never the host firewall.
set -eo pipefail
if [ "${1:-}" != --namespace ]; then
  if unshare -n true 2>/dev/null; then
    exec unshare -n bash "$0" --namespace
  elif sudo -n unshare -n true 2>/dev/null; then
    exec sudo -n unshare -n bash "$0" --namespace
  fi
  printf 'SKIP: list subnet replacement needs a network namespace and CAP_NET_ADMIN\n'
  exit 0
fi
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
APPLY="$TACHYON_LIB/nft/apply.uc"
TABLE=TachyonListRefreshTest
run() { ucode -L "$TACHYON_LIB" "$APPLY" "$@"; }
nft add table inet "$TABLE"
for name in tachyon_subnets tachyon_subnets6; do
  type=ipv4_addr
  [ "$name" != tachyon_subnets6 ] || type=ipv6_addr
  nft add set inet "$TABLE" "$name" "{ type $type; flags interval; auto-merge; }"
done
for family in ip ip6; do
  type=ipv4_addr
  [ "$family" != ip6 ] || type=ipv6_addr
  nft add set inet "$TABLE" "tachyon_${family}_ports" "{ type $type . inet_service; flags interval; }"
done
cat >"$WORK_DIR/fixture.json" <<JSON
{"section":[
 {".name":"direct","enabled":"1","action":"bypass","ip_cidr":["203.0.113.0/24","2001:db8:1::/48"],"domain_ip_lists":["$WORK_DIR/list"]},
 {".name":"scoped","enabled":"1","action":"proxy","ports":["443"],"ip_cidr":["203.0.114.0/24"]}
]}
JSON
prepare() {
  : >"$WORK_DIR/prefix"
  : >"$WORK_DIR/additions"
  TACHYON_NFT_BATCH_FILE="$WORK_DIR/prefix" run nft-prepare-list-refresh-fixture \
    "$WORK_DIR/fixture.json" "$TABLE" tachyon_subnets tachyon_subnets6 tachyon_ip_ports tachyon_ip6_ports
}
capture() {
  TACHYON_NFT_BATCH_FILE="$WORK_DIR/additions" run nft-add-subnet-file-for-section-fixture \
    "$WORK_DIR/fixture.json" "$1" "$2" "$TABLE" tachyon_subnets tachyon_ip_ports 5000 tachyon_subnets6 tachyon_ip6_ports
}
commit() { run nft-commit-list-refresh "$WORK_DIR/prefix" "$WORK_DIR/additions"; }
has() { nft get element inet "$TABLE" "$1" "{ $2 }" >/dev/null 2>&1; }
prepare
printf '198.18.0.0/15\n2001:db8:2::/48\n' >"$WORK_DIR/old"
capture direct "$WORK_DIR/old"
commit
has tachyon_rule_direct_subnets 198.18.0.6 || fail 'initial list missing'
prepare
capture direct "$WORK_DIR/old"
capture direct "$WORK_DIR/old"
commit
has tachyon_rule_direct_subnets6 2001:db8:2::1 || fail 'unchanged IPv6 list failed'
nft add element inet "$TABLE" tachyon_rule_direct_sources '{ 192.0.2.1 }'
before=$(nft -j list table inet "$TABLE")

prepare
printf '198.51.100.0/24\n2001:db8:3::/48\n' >"$WORK_DIR/new"
capture direct "$WORK_DIR/new"
# Two sources share a destination set. Both must survive one replacement.
printf '192.0.2.0/24\n' >"$WORK_DIR/shared"
capture direct "$WORK_DIR/shared"
printf '198.51.101.0/24\n' >"$WORK_DIR/scoped"
capture scoped "$WORK_DIR/scoped"
[ "$(nft -j list table inet "$TABLE")" = "$before" ] || fail 'preparation changed live firewall'
commit
if has tachyon_rule_direct_subnets 198.18.0.6; then fail 'deleted IPv4 subnet survived'; fi
if has tachyon_rule_direct_subnets6 2001:db8:2::1; then fail 'deleted IPv6 subnet survived'; fi
has tachyon_rule_direct_subnets 198.51.100.1 || fail 'new subnet missing'
has tachyon_rule_direct_subnets 192.0.2.1 || fail 'shared source was overwritten'
has tachyon_rule_direct_subnets 203.0.113.1 || fail 'inline IPv4 rule lost'
has tachyon_rule_direct_subnets6 2001:db8:1::1 || fail 'inline IPv6 rule lost'
has tachyon_rule_direct_sources 192.0.2.1 || fail 'source matcher lost'
has tachyon_rule_scoped_ip_ports '198.51.101.1 . 443' || fail 'scoped TCP list missing'
has tachyon_rule_scoped_udp_ip_ports '198.51.101.1 . 443' || fail 'scoped UDP list missing'

# An empty list must remove its last entries, preserving inline IP/port rules.
prepare
commit
if has tachyon_rule_direct_subnets 198.51.100.1; then fail 'empty list kept old entries'; fi
has tachyon_rule_direct_subnets 203.0.113.1 || fail 'empty list removed inline rule'
has tachyon_rule_scoped_ip_ports '203.0.114.1 . 443' || fail 'inline port rule lost'
if has tachyon_rule_scoped_ip_ports '198.51.101.1 . 443'; then fail 'scoped deletion failed'; fi

# A failing transaction must leave every previously active set intact.
before=$(nft -j list table inet "$TABLE")
prepare
printf 'add element inet %s nonexistent_set { 192.0.2.1 }\n' "$TABLE" >>"$WORK_DIR/additions"
if commit 2>/dev/null; then fail 'invalid transaction reported success'; fi
[ "$(nft -j list table inet "$TABLE")" = "$before" ] || fail 'failed transaction changed live sets'

prepare
printf '<html>upstream unavailable</html>\n' >"$WORK_DIR/bad.json"
if TACHYON_NFT_BATCH_FILE="$WORK_DIR/additions" run nft-add-json-ruleset-subnets-for-section-fixture \
  "$WORK_DIR/fixture.json" direct "$WORK_DIR/bad.json" invalid "$TABLE" tachyon_subnets tachyon_ip_ports \
  "$WORK_DIR/extracted" "$WORK_DIR/scoped-extracted" 5000 tachyon_subnets6 tachyon_ip6_ports; then
  fail 'malformed JSON was accepted as an empty list'
fi
[ "$(nft -j list table inet "$TABLE")" = "$before" ] || fail 'malformed source changed live sets'
for invalid_rule in \
  '{"ip_cidr":["198.51.100.0/33"]}' \
  '{"ip_cidr":["2001:db8::/129"]}' \
  '{"ip_cidr":["198.51.100.0/24"],"port":[70000]}' \
  '{"ip_cidr":["198.51.100.0/24"],"port_range":["443:80"]}' \
  '{"ip_cidr":["198.51.100.0/24"],"network":"tcpx"}' \
  '{"type":"logical","mode":"and","rules":[{"invert":true,"ip_cidr":["invalid"]}]}'; do
  prepare
  printf '{"version":3,"rules":[%s]}\n' "$invalid_rule" >"$WORK_DIR/bad.json"
  if TACHYON_NFT_BATCH_FILE="$WORK_DIR/additions" run nft-add-json-ruleset-subnets-for-section-fixture \
    "$WORK_DIR/fixture.json" direct "$WORK_DIR/bad.json" invalid "$TABLE" tachyon_subnets tachyon_ip_ports \
    "$WORK_DIR/extracted" "$WORK_DIR/scoped-extracted" 5000 tachyon_subnets6 tachyon_ip6_ports; then
    fail 'invalid JSON IP/port rule was accepted as an empty list'
  fi
done
[ "$(nft -j list table inet "$TABLE")" = "$before" ] || fail 'invalid JSON rules changed live sets'

# Preserve the existing non-interval fallback on kernels without pipapo.
for name in ip ip6; do
  setname="tachyon_rule_scoped_${name}_ports"
  type=ipv4_addr
  [ "$name" != ip6 ] || type=ipv6_addr
  nft delete set inet "$TABLE" "$setname"
  nft add set inet "$TABLE" "$setname" "{ type $type . inet_service; }"
done
prepare
printf '198.51.102.3\n2001:db8::5\n' >"$WORK_DIR/fallback"
capture scoped "$WORK_DIR/fallback"
commit
has tachyon_rule_scoped_ip_ports '198.51.102.3 . 443' || fail 'non-interval IPv4 set lost'
has tachyon_rule_scoped_ip6_ports '2001:db8::5 . 443' || fail 'non-interval IPv6 set lost'
prepare
commit
if has tachyon_rule_scoped_ip_ports '198.51.102.3 . 443'; then fail 'non-interval deletion failed'; fi

FIXTURE_JSON="$WORK_DIR/fixture.json" ucode -e '
let fs = require("fs"); let path = getenv("FIXTURE_JSON"); let data = json(fs.readfile(path));
push(data.section, {".name":"lastsource",enabled:"1",action:"bypass",domain_ip_lists:["/local/list.lst"]});
fs.writefile(path,sprintf("%J",data));'
prepare
printf '198.51.103.0/24\n' >"$WORK_DIR/lastsource"
capture lastsource "$WORK_DIR/lastsource"
commit
has tachyon_rule_lastsource_subnets 198.51.103.1 || fail 'last-source setup failed'
FIXTURE_JSON="$WORK_DIR/fixture.json" ucode -e '
let fs = require("fs"); let path = getenv("FIXTURE_JSON"); let data = json(fs.readfile(path));
for (let section in data.section) if (section[".name"] == "lastsource") delete section.domain_ip_lists;
fs.writefile(path,sprintf("%J",data));'
prepare
commit
if has tachyon_rule_lastsource_subnets 198.51.103.1; then fail 'removed last source left active entries'; fi
has tachyon_rule_direct_subnets 203.0.113.1 || fail 'last-source removal changed other section inline rules'
printf 'list subnet replacement tests passed\n'
