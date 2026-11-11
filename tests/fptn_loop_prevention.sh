#!/usr/bin/env bash
# Prevents router hard-freeze / TCP loopback storm when saving an FPTN section
# or outbound_source:
# 1. nft/apply.uc decodes fptn:/fptnb: server IPs into @tachyon_fptn_servers and
#    inserts early returns for FPTN_TUNNEL_BYPASS_MARK (0x00300000), tun-fptn*,
#    and FPTN server IPs in mangle, mangle_output, mangle_forward, and
#    importantly output_redirect (nat output priority -100).
# 2. providers/fptn/runtime.uc ip shim blocks split-default routes (0.0.0.0/1,
#    128.0.0.0/1, ::/0, ::/1, 8000::/1) from hijacking table main.
# 3. tachyon_core/generator_outbounds.uc forwards sni, bypass_method, and
#    preferred_server ordering to expanded FPTN member outbounds.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

NFT_RUNTIME="$ROOT_DIR/tachyon/files/usr/lib/nft/apply.uc"
GENERATOR_UC="$ROOT_DIR/tachyon/files/usr/lib/tachyon_core/generator.uc"
FPTN_RUNTIME_UC="$ROOT_DIR/tachyon/files/usr/lib/providers/fptn/runtime.uc"
NFT_LOG="$WORK_DIR/nft.log"
UCI_STATE="$WORK_DIR/uci.state"

mkdir -p "$WORK_DIR/bin"

cat >"$WORK_DIR/bin/nft" <<'EOF_NFT'
#!/usr/bin/env bash
set -eo pipefail
{
  printf 'nft'
  for arg in "$@"; do
    printf ' %s' "$arg"
  done
  printf '\n'
  if [ "${1:-}" = "-f" ] && [ -n "${2:-}" ] && [ -f "$2" ]; then
    cat "$2"
  fi
} >> "${NFT_LOG_TEST:?}"
exit 0
EOF_NFT
chmod +x "$WORK_DIR/bin/nft"

export PATH="$WORK_DIR/bin:$PATH"
export NFT_LOG_TEST="$NFT_LOG"

TOKEN_PAYLOAD='{"version":1,"service_name":"MyFPTN","username":"u1","password":"p1","servers":[{"name":"SrvA","host":"198.51.100.10","port":443},{"name":"SrvB","host":"203.0.113.20","port":8443}],"censorship_zone_servers":[{"name":"BridgeC","host":"192.0.2.30","port":443}]}'
TOKEN="fptn:$(printf '%s' "$TOKEN_PAYLOAD" | base64 | tr -d '\n')"

cat >"$UCI_STATE" <<EOF_UCI
tachyon.settings=settings
tachyon.settings.enabled=1
tachyon.settings.proxy_mode=tproxy
tachyon.settings.source_network_interfaces=br-lan
tachyon.settings.route_router_traffic=1
tachyon.settings.route_router_traffic_section=FptnMain
tachyon.FptnMain=section
tachyon.FptnMain.enabled=1
tachyon.FptnMain.action=fptn
tachyon.FptnMain.access_token=$TOKEN
EOF_UCI

: >"$NFT_LOG"
TACHYON_UCI_STATE_FILE="$UCI_STATE" \
  ucode -L "$TACHYON_LIB" "$NFT_RUNTIME" nft-create-runtime-base-from-uci \
  TachyonTable localv4 tachyon_subnets tachyon_ports tachyon_ip_ports tachyon_interfaces \
  0x04000000 0x08000000 198.18.0.0/15 1602 localv6 tachyon_subnets6 tachyon_ip6_ports fc00::/18 ::1

grep -Fq "tachyon_fptn_servers" "$NFT_LOG" || {
  cat "$NFT_LOG" >&2
  fail "missing @tachyon_fptn_servers set creation in nft-create-runtime-base"
}
grep -Fq "198.51.100.10" "$NFT_LOG" || fail "missing decoded FPTN server 198.51.100.10 in nft set"
grep -Fq "203.0.113.20" "$NFT_LOG" || fail "missing decoded FPTN server 203.0.113.20 in nft set"
grep -Fq "192.0.2.30" "$NFT_LOG" || fail "missing decoded FPTN censorship_zone_server 192.0.2.30 in nft set"
grep -Fq "mangle_output ip daddr @tachyon_fptn_servers counter return" "$NFT_LOG" ||
  fail "missing @tachyon_fptn_servers return rule in mangle_output"
grep -Fq "mangle_output meta mark & 0x00300000 == 0x00300000 counter return" "$NFT_LOG" ||
  fail "missing FPTN_TUNNEL_BYPASS_MARK return rule in mangle_output"
grep -Fq 'mangle iifname "tun-fptn*"' "$NFT_LOG" ||
  fail "missing tun-fptn* bypass in mangle"
grep -Fq 'mangle_forward oifname "tun-fptn*" return' "$NFT_LOG" ||
  fail "missing tun-fptn* bypass in mangle_forward"

# Critical check: output_redirect (router self-traffic NAT redirect) MUST bypass
# FPTN server IPs, tun-fptn*, and mark 0x00300000 before redirecting all TCP to :1601!
: >"$NFT_LOG"
TACHYON_UCI_STATE_FILE="$UCI_STATE" \
  ucode -L "$TACHYON_LIB" "$NFT_RUNTIME" nft-enable-router-output-intercept \
  TachyonTable localv4 0x08000000 0

grep -Fq "output_redirect meta mark & 0x00300000 == 0x00300000 return" "$NFT_LOG" || {
  cat "$NFT_LOG" >&2
  fail "output_redirect is missing 0x00300000 return rule (causes loopback storm)"
}
grep -Fq 'output_redirect oifname "tun-fptn*" return' "$NFT_LOG" ||
  fail "output_redirect is missing tun-fptn* return rule"
grep -Fq "198.51.100.10" "$NFT_LOG" ||
  fail "output_redirect is missing decoded FPTN server IP 198.51.100.10 return rule"

# Verify ip shim blocks 0.0.0.0/1 and 128.0.0.0/1 split-default routes
REAL_IP_LOG="$WORK_DIR/real_ip.log"
mkdir -p "$WORK_DIR/realbin" "$WORK_DIR/fptn-state/bin"
cat >"$WORK_DIR/realbin/ip" <<'EOF_REAL_IP'
#!/bin/sh
printf '%s\n' "$*" >> "${REAL_IP_LOG_TEST:?}"
exit 0
EOF_REAL_IP
chmod +x "$WORK_DIR/realbin/ip"

ucode -L "$TACHYON_LIB" -e '
let fs = require("fs");
let src = fs.readfile(ARGV[0]);
if (index(src, "*0.0.0.0/1*|*128.0.0.0/1*") < 0 || index(src, "*::/0*|*::/1*|*8000::/1*") < 0) {
    warn("ip_shim in providers/fptn/runtime.uc does not block /1 split-default routes\n");
    exit(1);
}
' "$FPTN_RUNTIME_UC"

# Verify generator forwards sni, bypass_method, and preferred_server ordering
printf 'tachyon-core\n' > "$WORK_DIR/sing-box-variant"
export SB_VARIANT_STATE_FILE="$WORK_DIR/sing-box-variant"
export TACHYON_PERSISTENT_SELECTOR_STATE_FILE="$WORK_DIR/selector_state.json"

cat >"$WORK_DIR/fixture_fptn_opts.json" <<EOF_JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "FptnOpt",
      ".type": "section",
      "enabled": "1",
      "action": "fptn",
      "match_all": "1",
      "access_token": "$TOKEN",
      "sni": "cdn.example.org",
      "bypass_method": "obfuscation",
      "preferred_server": "203.0.113.20"
    }
  ]
}
EOF_JSON

mkdir -p "$WORK_DIR/out_opts.json.section-cache" "$WORK_DIR/out_opts.json.rulesets"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture_fptn_opts.json" "$WORK_DIR/out_opts.json" "127.0.0.1" "0" "1"

ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));
let by_tag = {};
for (let o in cfg.outbounds || []) {
    if (type(o) == "object" && o.tag != null)
        by_tag[o.tag] = o;
}
let srv_b = by_tag["FptnOpt-out/SrvB"];
if (srv_b == null || srv_b.sni != "cdn.example.org" || srv_b.bypass_method != "obfuscation") {
    warn("expanded FPTN member did not inherit sni/bypass_method: " + sprintf("%J", srv_b) + "\n");
    exit(1);
}
let ut = by_tag["FptnOpt-urltest-out"];
if (ut == null || type(ut.outbounds) != "array" || ut.outbounds[0] != "FptnOpt-out/SrvB") {
    warn("preferred_server SrvB was not ordered first in urltest outbounds: " + sprintf("%J", ut) + "\n");
    exit(1);
}
' "$WORK_DIR/out_opts.json"

printf 'FPTN loop prevention checks passed\n'
