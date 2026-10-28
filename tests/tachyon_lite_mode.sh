#!/usr/bin/env bash
# Regression test for Tachyon Lite ("Эко-режим" for constrained MIPS/MIPSEL routers):
#   1. Process isolation via procd nice 15 + live renice
#   2. nftables ct mark short-circuit & per-client connlimit
#   3. Aggressive conntrack & socket buffer tuning via sysctl
#   4. Control Plane hibernation in watchdog under high Data Plane load
#   5. Read/Write RPC surface & UI state toggle

. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

set -eo pipefail

MOCK_BIN="$WORK_DIR/bin"
UCI_STATE="$WORK_DIR/uci.state"
SYSCTL_LOG="$WORK_DIR/sysctl.log"
NFT_LOG="$WORK_DIR/nft_rules.nft"
mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/sysctl" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-n" ]; then
  case "$2" in
    net.netfilter.nf_conntrack_max) echo "16384" ;;
    net.core.rmem_max|net.core.wmem_max) echo "524288" ;;
    *) echo "0" ;;
  esac
  exit 0
fi
printf '%s\n' "$*" >> "$SYSCTL_LOG_PATH"
exit 0
EOF
chmod +x "$MOCK_BIN/sysctl"

cat > "$MOCK_BIN/nft" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NFT_LOG_PATH"
for arg in "$@"; do
  if [ -f "$arg" ]; then
    cat "$arg" >> "$NFT_LOG_PATH"
  fi
done
exit 0
EOF
chmod +x "$MOCK_BIN/nft"

cat > "$MOCK_BIN/ip" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "route" ]; then
  echo "default via 192.168.1.1 dev eth0"
fi
exit 0
EOF
chmod +x "$MOCK_BIN/ip"

export PATH="$MOCK_BIN:$PATH"
export TACHYON_UCI_STATE_FILE="$UCI_STATE"
export SYSCTL_LOG_PATH="$SYSCTL_LOG"
export NFT_LOG_PATH="$NFT_LOG"

write_tachyon_uci() {
  local lite_val="$1"
  cat > "$UCI_STATE" <<EOF
tachyon.settings=tachyon
tachyon.settings.enabled=1
tachyon.settings.lite_mode=$lite_val
tachyon.settings.mode=tun
tachyon.settings.proxy_mode=1
tachyon.settings.fakeip_mark=0x01000000
tachyon.settings.mark=0x02000000
tachyon.settings.routing_port=7894
tachyon.settings.tproxy_port=7895
tachyon.main=section
tachyon.main.enabled=1
tachyon.main.mode=tun
tachyon.main.interface=tachyon0
network.lan=interface
network.lan.device=br-lan
network.lan.proto=static
network.lan.ipaddr=192.168.1.1
dhcp.main=dnsmasq
dhcp.main.port=53
EOF
}

# 1. Process isolation: managed_core_init_script emits procd_set_param nice 15 gated on lite_mode
ucode -L "$TACHYON_LIB" "$TACHYON_LIB/core/process.uc" selftest >/dev/null ||
  fail "core/process.uc selftest failed"

init_script="$(ucode -L "$TACHYON_LIB" -e '
  let proc = require("core.process");
  print(proc.managed_core_init_script());
')"
printf '%s\n' "$init_script" | grep -q 'uci get tachyon.settings.lite_mode' ||
  fail "managed_core_init_script missing UCI lite_mode lookup"
printf '%s\n' "$init_script" | grep -q "procd_set_param nice 15" ||
  fail "managed_core_init_script missing procd_set_param nice 15"

# 2. nftables Short-Circuit & Connlimit + 3. Conntrack/Buffer sysctl tuning (lite_mode = 1)
write_tachyon_uci "1"
rm -f "$SYSCTL_LOG" "$NFT_LOG"

ucode -L "$TACHYON_LIB" "$TACHYON_LIB/nft/apply.uc" nft-create-runtime-base-from-uci \
  TachyonTable localv4 tachyon_subnets tachyon_ports tachyon_ip_ports tachyon_interfaces \
  0x01000000 0x02000000 198.18.0.0/15 7895 localv6 tachyon_subnets6 tachyon_ip6_ports fc00::/18 ::1 >/dev/null

[ -f "$NFT_LOG" ] || fail "nft-create-runtime-base did not invoke nft with a ruleset file"

grep -q 'ct mark 0x00800000 counter return comment "tachyon-lite-shortcircuit-direct"' "$NFT_LOG" ||
  fail "missing tachyon-lite-shortcircuit-direct in nft ruleset when lite_mode=1"
grep -q 'ct mark 0x00400000 meta mark set 0x01000000 counter return comment "tachyon-lite-shortcircuit-proxy"' "$NFT_LOG" ||
  fail "missing tachyon-lite-shortcircuit-proxy in nft ruleset when lite_mode=1"
grep -q 'ct state new tcp dport != { 53, 80, 443 } ct count over 256 counter drop comment "tachyon-lite-connlimit"' "$NFT_LOG" ||
  fail "missing tachyon-lite-connlimit in nft ruleset when lite_mode=1"
grep -q 'ct mark set 0x00400000 comment "tachyon-lite-mark-proxy"' "$NFT_LOG" ||
  fail "missing tachyon-lite-mark-proxy in nft ruleset when lite_mode=1"
grep -q 'ct mark set 0x00800000 comment "tachyon-lite-mark-direct"' "$NFT_LOG" ||
  fail "missing tachyon-lite-mark-direct in nft ruleset when lite_mode=1"

# Verify Short-Circuit precedes jump priority_rules in chain mangle
sc_line="$(grep -n 'tachyon-lite-shortcircuit-direct' "$NFT_LOG" | head -1 | cut -d: -f1)"
prio_line="$(grep -n 'jump priority_rules' "$NFT_LOG" | head -1 | cut -d: -f1)"
[ -n "$sc_line" ] && [ -n "$prio_line" ] && [ "$sc_line" -lt "$prio_line" ] ||
  fail "Short-Circuit rules must appear before jump priority_rules in chain mangle (sc=$sc_line, prio=$prio_line)"

rm -f "$SYSCTL_LOG"
ucode -L "$TACHYON_LIB" "$TACHYON_LIB/nft/apply.uc" apply-connection-tuning >/dev/null

[ -f "$SYSCTL_LOG" ] || fail "apply-connection-tuning did not invoke sysctl"
grep -q 'net.netfilter.nf_conntrack_tcp_timeout_established=600' "$SYSCTL_LOG" ||
  fail "lite_mode=1 must set nf_conntrack_tcp_timeout_established=600"
grep -q 'net.netfilter.nf_conntrack_max=8192' "$SYSCTL_LOG" ||
  fail "lite_mode=1 must cap nf_conntrack_max=8192"
grep -q 'net.core.rmem_max=262144' "$SYSCTL_LOG" ||
  fail "lite_mode=1 must cap net.core.rmem_max=262144"
grep -q 'net.core.wmem_max=262144' "$SYSCTL_LOG" ||
  fail "lite_mode=1 must cap net.core.wmem_max=262144"

# Verify lite_mode = 0 omits Short-Circuit rules and restores normal sysctl bounds
write_tachyon_uci "0"
rm -f "$SYSCTL_LOG" "$NFT_LOG"

ucode -L "$TACHYON_LIB" "$TACHYON_LIB/nft/apply.uc" nft-create-runtime-base-from-uci \
  TachyonTable localv4 tachyon_subnets tachyon_ports tachyon_ip_ports tachyon_interfaces \
  0x01000000 0x02000000 198.18.0.0/15 7895 localv6 tachyon_subnets6 tachyon_ip6_ports fc00::/18 ::1 >/dev/null

if grep -q 'tachyon-lite-' "$NFT_LOG"; then
  fail "nft ruleset must not contain tachyon-lite-* rules when lite_mode=0"
fi

ucode -L "$TACHYON_LIB" "$TACHYON_LIB/nft/apply.uc" apply-connection-tuning >/dev/null

grep -q 'net.netfilter.nf_conntrack_tcp_timeout_time_wait=30' "$SYSCTL_LOG" ||
  fail "lite_mode=0 must set nf_conntrack_tcp_timeout_time_wait=30"
grep -q 'net.netfilter.nf_conntrack_max=65536' "$SYSCTL_LOG" ||
  fail "lite_mode=0 must set nf_conntrack_max=65536"
grep -q 'net.core.rmem_max=2621440' "$SYSCTL_LOG" ||
  fail "lite_mode=0 must set net.core.rmem_max=2621440"

# 4. Control Plane Hibernation in service/watchdog.uc
STAT_FILE="$WORK_DIR/proc_stat"
LOAD_FILE="$WORK_DIR/proc_loadavg"
rm -f /tmp/tachyon_lite_cpu.stat

cat > "$STAT_FILE" <<'EOF'
cpu  100 0 0 100 0 0 0 0 0 0
EOF
cat > "$LOAD_FILE" <<'EOF'
0.20 0.15 0.10 1/64 1000
EOF

# Baseline sample (no delta yet, low loadavg -> returns 0)
write_tachyon_uci "1"
busy_out="$(ucode -L "$TACHYON_LIB" "$TACHYON_LIB/service/watchdog.uc" lite-busy-check "$STAT_FILE" "$LOAD_FILE")"
[ "$busy_out" = "0" ] || fail "initial baseline sample with low loadavg must return 0 (got $busy_out)"

# Second sample: +85 busy ticks, +15 idle ticks (85% busy >= 75%) -> returns 1
cat > "$STAT_FILE" <<'EOF'
cpu  185 0 0 115 0 0 0 0 0 0
EOF
busy_out="$(ucode -L "$TACHYON_LIB" "$TACHYON_LIB/service/watchdog.uc" lite-busy-check "$STAT_FILE" "$LOAD_FILE")"
[ "$busy_out" = "1" ] || fail "85% CPU delta in lite_mode=1 must return 1 (got $busy_out)"

# Third sample: +10 busy ticks, +90 idle ticks (10% busy < 75%, loadavg 0.20 < 0.85) -> returns 0
cat > "$STAT_FILE" <<'EOF'
cpu  195 0 0 205 0 0 0 0 0 0
EOF
busy_out="$(ucode -L "$TACHYON_LIB" "$TACHYON_LIB/service/watchdog.uc" lite-busy-check "$STAT_FILE" "$LOAD_FILE")"
[ "$busy_out" = "0" ] || fail "10% CPU delta and 0.20 loadavg in lite_mode=1 must return 0 (got $busy_out)"

# Fourth sample: low tick delta but high loadavg (1.15 >= 0.85) -> returns 1
cat > "$STAT_FILE" <<'EOF'
cpu  205 0 0 295 0 0 0 0 0 0
EOF
cat > "$LOAD_FILE" <<'EOF'
1.15 0.90 0.50 2/64 1001
EOF
busy_out="$(ucode -L "$TACHYON_LIB" "$TACHYON_LIB/service/watchdog.uc" lite-busy-check "$STAT_FILE" "$LOAD_FILE")"
[ "$busy_out" = "1" ] || fail "loadavg 1.15 in lite_mode=1 must return 1 (got $busy_out)"

# When lite_mode=0, even high loadavg must return 0
write_tachyon_uci "0"
busy_out="$(ucode -L "$TACHYON_LIB" "$TACHYON_LIB/service/watchdog.uc" lite-busy-check "$STAT_FILE" "$LOAD_FILE")"
[ "$busy_out" = "0" ] || fail "lite-busy-check must return 0 when lite_mode=0 (got $busy_out)"
rm -f /tmp/tachyon_lite_cpu.stat

# 5. RPC surface check: get_lite_mode in read+write, set_lite_mode in write only + ui.uc toggle
grep -q 'get_lite_mode:' "$ROOT_DIR/tachyon/files/usr/bin/tachyon-read" ||
  fail "get_lite_mode must be present in tachyon-read"
if grep -q 'set_lite_mode:' "$ROOT_DIR/tachyon/files/usr/bin/tachyon-read"; then
  fail "set_lite_mode must NOT be present in tachyon-read"
fi
grep -q 'set_lite_mode:' "$ROOT_DIR/tachyon/files/usr/bin/tachyon" ||
  fail "set_lite_mode must be present in /usr/bin/tachyon"

ui_set_on="$(ucode -L "$TACHYON_LIB" "$TACHYON_LIB/service/ui.uc" set-lite-mode 1)"
printf '%s' "$ui_set_on" | grep -q '"lite_mode": *1' ||
  fail "ui.uc set-lite-mode 1 must return lite_mode: 1 (got $ui_set_on)"
ui_get_on="$(ucode -L "$TACHYON_LIB" "$TACHYON_LIB/service/ui.uc" get-lite-mode)"
printf '%s' "$ui_get_on" | grep -q '"lite_mode": *1' ||
  fail "ui.uc get-lite-mode must return lite_mode: 1 after enabling (got $ui_get_on)"

ui_set_off="$(ucode -L "$TACHYON_LIB" "$TACHYON_LIB/service/ui.uc" set-lite-mode 0)"
printf '%s' "$ui_set_off" | grep -q '"lite_mode": *0' ||
  fail "ui.uc set-lite-mode 0 must return lite_mode: 0 (got $ui_set_off)"

# 6. Server open_firewall_port sync (sync-server-firewall-uci-rules)
cat >> "$UCI_STATE" <<'EOF'
tachyon.srv123=server
tachyon.srv123.enabled=1
tachyon.srv123.protocol=awg
tachyon.srv123.listen_port=51820
tachyon.srv123.open_firewall_port=1
EOF

ucode -L "$TACHYON_LIB" "$TACHYON_LIB/nft/apply.uc" sync-server-firewall-uci-rules >/dev/null
grep -q 'firewall.tachyon_srv_srv123.dest_port=51820' "$UCI_STATE" ||
  fail "sync-server-firewall-uci-rules must create firewall.tachyon_srv_srv123.dest_port=51820"
grep -q 'firewall.tachyon_srv_srv123.proto=udp' "$UCI_STATE" ||
  fail "sync-server-firewall-uci-rules must set proto=udp for awg server"

# 7. Section isolation: Section 2 with inline VLESS link must NOT inherit Section 1's subscription via shared balancer/group
sec_isolation="$(ucode -L "$TACHYON_LIB" -e '
  let conn = require("config.connections");
  let fixture = {
    outbound_source: [
      {
        ".name": "src_sub1",
        ".type": "outbound_source",
        enabled: "1",
        source_type: "subscription",
        url: "https://example.com/sub1"
      }
    ],
    outbound_group: [
      {
        ".name": "grp_all",
        ".type": "outbound_group",
        enabled: "1"
      }
    ],
    balancer: [
      {
        ".name": "bal_urltest",
        ".type": "balancer",
        enabled: "1",
        mode: "urltest",
        source_refs: [ "src_sub1" ]
      }
    ],
    section: [
      {
        ".name": "main",
        ".type": "section",
        enabled: "1",
        connection_type: "proxy",
        outbound_source_refs: [ "src_sub1" ],
        balancer_refs: [ "bal_urltest" ]
      },
      {
        ".name": "ai",
        ".type": "section",
        enabled: "1",
        connection_type: "proxy",
        connection_urls: [ "vless://11111111-1111-1111-1111-111111111111@1.2.3.4:443?security=none&type=tcp#AI-Single" ],
        outbound_group_refs: [ "grp_all" ],
        balancer_refs: [ "bal_urltest" ]
      }
    ]
  };
  conn.set_item_sections_from_data(fixture);
  print(sprintf("main_subs=%J ai_subs=%J ai_urls=%J",
    conn.subscription_urls(fixture.section[0]),
    conn.subscription_urls(fixture.section[1]),
    conn.connection_urls(fixture.section[1])
  ));
')"
printf '%s' "$sec_isolation" | grep -q 'ai_subs=\[ \]' ||
  fail "Section ai with inline VLESS link must have empty subscription_urls (got: $sec_isolation)"
printf '%s' "$sec_isolation" | grep -q 'AI-Single' ||
  fail "Section ai must preserve its inline VLESS link (got: $sec_isolation)"

printf 'PASS: Tachyon Lite mode (procd nice, nft short-circuit/connlimit, sysctl tuning, watchdog hibernation, RPC surface, server firewall port, section isolation)\n'
