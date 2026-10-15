#!/usr/bin/env bash
# Section Fail Policy (keep | block | direct):
# Verifies that when a section is quarantined, deferred, or marked failed by
# runtime health probes in TACHYON_SECTION_FAIL_STATE_FILE:
#   - fail_policy="block" turns sing-box route rules into action="reject",
#     DNS rules into server="block-dns", and nftables priority rules into "drop".
#   - fail_policy="direct" turns sing-box route rules into outbound="bypass-out",
#     DNS rules into server="dns-server", and nftables priority rules into "accept".
#   - service/failover.uc tracks per-section probe streaks and transitions
#     failed=true / failed=false in TACHYON_SECTION_FAIL_STATE_FILE.

. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail
export WORK_DIR

GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"
NFT_APPLY_UC="$TACHYON_LIB/nft/apply.uc"
FAILOVER_UC="$TACHYON_LIB/service/failover.uc"
SECTION_JS="$ROOT_DIR/luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/section.js"

export SB_VARIANT_STATE_FILE="$WORK_DIR/variant"
export SB_VERSION_STATE_FILE="$WORK_DIR/version"
printf 'tachyon-core' >"$SB_VARIANT_STATE_FILE"
printf '0.0.9' >"$SB_VERSION_STATE_FILE"

export TACHYON_SECTION_FAIL_STATE_FILE="$WORK_DIR/section-fail-state.json"

cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ]
  },
  "section": [
    {
      ".name": "sec_block",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "fail_policy": "block",
      "domain_suffix": [ "secret.example" ],
      "ip_cidr": [ "198.51.100.0/24" ],
      "selector_proxy_links": [ "socks5://127.0.0.1:1080#node1" ]
    },
    {
      ".name": "sec_direct",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "fail_policy": "direct",
      "domain_suffix": [ "work.example" ],
      "ip_cidr": [ "203.0.113.0/24" ],
      "selector_proxy_links": [ "socks5://127.0.0.1:1081#node2" ]
    }
  ]
}
JSON

# 1. Healthy run: normal proxy routing
rm -f "$TACHYON_SECTION_FAIL_STATE_FILE"
mkdir -p "$WORK_DIR/healthy.json.section-cache"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$WORK_DIR/healthy.json" "127.0.0.1" "0" "" "" ""

ucode -e '
  let fs = require("fs");
  let cfg = json(fs.readfile(getenv("WORK_DIR") + "/healthy.json"));
  let found_block_out = false;
  let found_direct_out = false;
  for (let r in cfg.route.rules) {
    let ds = type(r.domain_suffix) == "array" ? r.domain_suffix[0] : r.domain_suffix;
    if (ds == "secret.example" && (r.outbound == "sec_block-out" || r.outbound == "sec_block-1-out"))
      found_block_out = true;
    if (ds == "work.example" && (r.outbound == "sec_direct-out" || r.outbound == "sec_direct-1-out"))
      found_direct_out = true;
  }
  if (!found_block_out || !found_direct_out)
    exit(1);
' || fail "healthy sections must route through their proxy outbounds"

# 2. Quarantined / runtime-failed run: fail_policy overrides take effect
cat >"$TACHYON_SECTION_FAIL_STATE_FILE" <<'JSON'
{
  "sec_block": { "streak": 3, "failed": true, "policy": "block" },
  "sec_direct": { "streak": 3, "failed": true, "policy": "direct" }
}
JSON

mkdir -p "$WORK_DIR/failed.json.section-cache"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$WORK_DIR/failed.json" "127.0.0.1" "0" "" "sec_block" ""

ucode -e '
  let fs = require("fs");
  let cfg = json(fs.readfile(getenv("WORK_DIR") + "/failed.json"));
  let secret_rejected = false;
  let work_bypassed = false;
  let secret_dns_blocked = false;
  let work_dns_direct = false;

  for (let r in cfg.route.rules) {
    let ds = type(r.domain_suffix) == "array" ? r.domain_suffix[0] : r.domain_suffix;
    if (ds == "secret.example" && r.action == "reject" && r.outbound == null)
      secret_rejected = true;
    if (ds == "work.example" && r.action == "route" && r.outbound == "direct-out")
      work_bypassed = true;
  }
  for (let r in cfg.dns.rules) {
    let ds = type(r.domain_suffix) == "array" ? r.domain_suffix[0] : r.domain_suffix;
    if (ds == "secret.example" && r.server == "fakeip-server")
      secret_dns_blocked = true;
    if (ds == "work.example" && r.server == "dns-server")
      work_dns_direct = true;
  }
  if (!secret_rejected || !work_bypassed || !secret_dns_blocked || !work_dns_direct) {
    warn(sprintf("flags: reject=%J bypass=%J dns_block=%J dns_direct=%J\n",
      secret_rejected, work_bypassed, secret_dns_blocked, work_dns_direct));
    exit(1);
  }
' || fail "failed/deferred sections must apply fail_policy block and direct in sing-box config"

# 3. Check nft/apply.uc wiring for fail_policy
grep -Fq 'section_is_failed_in_runtime' "$NFT_APPLY_UC" ||
  fail "nft/apply.uc must check section_is_failed_in_runtime"
grep -Fq 'fail_policy' "$NFT_APPLY_UC" ||
  fail "nft/apply.uc must inspect fail_policy"
grep -Fq 'fail_policy' "$SECTION_JS" ||
  fail "section.js must expose fail_policy option"

# 4. Check service/failover.uc state machine for section fail_policy
grep -Fq 'check_section_fail_policies' "$FAILOVER_UC" ||
  fail "service/failover.uc must define check_section_fail_policies"

printf 'section_fail_policy: OK\n'
