#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

NFT_RUNTIME="$ROOT_DIR/tachyon/files/usr/lib/nft/apply.uc"
GENERATOR="$ROOT_DIR/tachyon/files/usr/lib/tachyon_core/generator.uc"
NFT_LOG="$WORK_DIR/nft.log"
NFT_BATCH_DUMP="$WORK_DIR/nft_batch_dump.txt"
UCI_LOG="$WORK_DIR/uci.log"
UCI_STATE="$WORK_DIR/uci.state"

mkdir -p "$WORK_DIR/bin"

cat >"$WORK_DIR/bin/nft" <<'EOF_NFT'
#!/usr/bin/env bash
set -eo pipefail
{
  printf 'nft'
  for arg in "$@"; do
    printf '\t%s' "$arg"
  done
  printf '\n'
} >> "${NFT_LOG_TEST:?}"

if [ "$1" = "-f" ] && [ -f "$2" ]; then
  cat "$2" >> "${NFT_BATCH_DUMP_TEST:?}"
  exit 0
fi

if [ "$1" = "list" ] && [ "$2" = "chain" ] && [ "$3" = "inet" ] && [ "$4" = "fw4" ] && [ "$5" = "input" ]; then
  printf '%s' "${MOCK_FW4_INPUT:-}"
  exit 0
fi

exit 0
EOF_NFT
chmod +x "$WORK_DIR/bin/nft"

cat >"$WORK_DIR/bin/ip" <<'EOF_IP'
#!/usr/bin/env bash
if [ "$1" = "route" ] && [ "$2" = "show" ]; then
  printf 'local default dev lo scope host\n'
  exit 0
fi
if [ "$1" = "-6" ] && [ "$2" = "route" ] && [ "$3" = "show" ]; then
  printf 'local default dev lo metric 1024 pref medium\n'
  exit 0
fi
if [ "$1" = "-4" ] && [ "$2" = "rule" ] && [ "$3" = "show" ]; then
  printf '105:\tfrom all fwmark 0x100000/0x100000 lookup TachyonTable\n'
  exit 0
fi
if [ "$1" = "-6" ] && [ "$2" = "rule" ] && [ "$3" = "show" ]; then
  printf '105:\tfrom all fwmark 0x100000/0x100000 lookup TachyonTable\n'
  exit 0
fi
exit 0
EOF_IP
chmod +x "$WORK_DIR/bin/ip"

export PATH="$WORK_DIR/bin:$PATH"
export NFT_LOG_TEST="$NFT_LOG"
export NFT_BATCH_DUMP_TEST="$NFT_BATCH_DUMP"

# 1. sync-server-firewall-uci-rules in TProxy mode without firewall.tachyon_tun must NOT commit firewall
#    and grouped port set { 443, 8443 } in fw4 input chain must be recognized without inserting duplicate rules.
cat >"$UCI_STATE" <<'EOF_UCI'
tachyon.settings=settings
tachyon.settings.proxy_mode=tproxy
tachyon.srv1=server
tachyon.srv1.enabled=1
tachyon.srv1.open_firewall_port=1
tachyon.srv1.type=vless
tachyon.srv1.listen_port=443
tachyon.srv2=server
tachyon.srv2.enabled=1
tachyon.srv2.open_firewall_port=1
tachyon.srv2.type=vless
tachyon.srv2.listen_port=8443
firewall.tachyon_srv_srv1=rule
firewall.tachyon_srv_srv1.name=Tachyon server srv1
firewall.tachyon_srv_srv1.src=wan
firewall.tachyon_srv_srv1.dest_port=443
firewall.tachyon_srv_srv1.proto=tcp udp
firewall.tachyon_srv_srv1.target=ACCEPT
firewall.tachyon_srv_srv1.enabled=1
firewall.tachyon_srv_srv2=rule
firewall.tachyon_srv_srv2.name=Tachyon server srv2
firewall.tachyon_srv_srv2.src=wan
firewall.tachyon_srv_srv2.dest_port=8443
firewall.tachyon_srv_srv2.proto=tcp udp
firewall.tachyon_srv_srv2.target=ACCEPT
firewall.tachyon_srv_srv2.enabled=1
EOF_UCI

: >"$UCI_LOG"
: >"$NFT_LOG"
MOCK_FW4_INPUT=$'table inet fw4 {\n\tchain input {\n\t\ttcp dport { 443, 8443 } accept\n\t\tudp dport { 443, 8443 } accept\n\t}\n}\n' \
  TACHYON_UCI_STATE_FILE="$UCI_STATE" \
  TACHYON_UCI_LOG_FILE="$UCI_LOG" \
  ucode -L "$TACHYON_LIB" "$NFT_RUNTIME" sync-server-firewall-uci-rules

if grep -Fq "commit firewall" "$UCI_LOG" || grep -Fq "delete firewall.tachyon_tun" "$UCI_LOG"; then
  cat "$UCI_LOG" >&2
  fail "sync-server-firewall-uci-rules committed/deleted absent firewall.tachyon_tun in tproxy mode"
fi

if grep -Fq $'nft\tinsert\trule\tinet\tfw4\tinput' "$NFT_LOG"; then
  cat "$NFT_LOG" >&2
  fail "sync-server-firewall-uci-rules failed to recognize grouped dport { 443, 8443 } in fw4 input"
fi

# 2. ensure-tproxy-route-rule must not attempt 'nft insert rule inet fw4 input' when fw4 chain output is empty,
#    and must not rewrite unchanged rt_tables.
RT_TABLES="$WORK_DIR/rt_tables"
printf '105 TachyonTable\n' >"$RT_TABLES"
touch -d '2020-01-01 00:00:00 UTC' "$RT_TABLES"
before_mtime="$(stat -c %Y "$RT_TABLES")"

: >"$NFT_LOG"
MOCK_FW4_INPUT="" \
  TACHYON_UCI_STATE_FILE="$UCI_STATE" \
  TACHYON_UCI_LOG_FILE="$UCI_LOG" \
  ucode -L "$TACHYON_LIB" "$NFT_RUNTIME" ensure-tproxy-route-rule TachyonTable 0x00100000 "$RT_TABLES"

after_mtime="$(stat -c %Y "$RT_TABLES")"
if [ "$before_mtime" != "$after_mtime" ]; then
  fail "ensure_rt_table_entry rewrote unchanged rt_tables ($before_mtime -> $after_mtime)"
fi

if grep -Fq $'nft\tinsert\trule\tinet\tfw4\tinput' "$NFT_LOG"; then
  cat "$NFT_LOG" >&2
  fail "ensure-tproxy-route-rule inserted into missing fw4 input chain"
fi

# 3. TACHYON_FORCE_NFT_BATCH=1 in nft-populate-runtime-sets-from-uci coalesces same-set additions into one nft -f call.
cat >"$WORK_DIR/local_subnets.json" <<'EOF_JSON_RS'
{"version":1,"rules":[{"ip_cidr":["192.0.2.0/24","198.51.100.0/24"]}]}
EOF_JSON_RS

cat >"$UCI_STATE" <<EOF_POP_UCI
tachyon.settings=settings
tachyon.settings.source_network_interfaces=br-lan
tachyon.sec1=section
tachyon.sec1.enabled=1
tachyon.sec1.action=connection
tachyon.sec1.ip_cidr=198.51.100.0/24 203.0.113.0/24
tachyon.sec1.rule_set_with_subnets=$WORK_DIR/local_subnets.json
tachyon.sec2=section
tachyon.sec2.enabled=1
tachyon.sec2.action=connection
tachyon.sec2.ip_cidr=198.18.0.0/15
EOF_POP_UCI

: >"$NFT_LOG"
: >"$NFT_BATCH_DUMP"
TACHYON_FORCE_NFT_BATCH=1 \
  TACHYON_UCI_STATE_FILE="$UCI_STATE" \
  ucode -L "$TACHYON_LIB" "$NFT_RUNTIME" nft-populate-runtime-sets-from-uci \
  1 "" TachyonTable tachyon_subnets tachyon_ports tachyon_ip_ports tachyon_interfaces localv4 0x00100000 tachyon_subnets6 tachyon_ip6_ports localv6

nft_f_calls="$(grep -c $'^nft\t-f\t' "$NFT_LOG" || true)"
if [ "$nft_f_calls" -ne 1 ]; then
  cat "$NFT_LOG" >&2
  fail "expected exactly 1 batched 'nft -f' call, got $nft_f_calls"
fi

subnet_lines="$(grep -c '^add element inet TachyonTable tachyon_rule_sec1_subnets ' "$NFT_BATCH_DUMP" || true)"
if [ "$subnet_lines" -ne 1 ]; then
  cat "$NFT_BATCH_DUMP" >&2
  fail "expected coalesced single add element line for tachyon_rule_sec1_subnets, got $subnet_lines"
fi
grep -Fq "198.51.100.0/24" "$NFT_BATCH_DUMP" || fail "missing 198.51.100.0/24 in coalesced batch"
grep -Fq "203.0.113.0/24" "$NFT_BATCH_DUMP" || fail "missing 203.0.113.0/24 in coalesced batch"
grep -Fq "192.0.2.0/24" "$NFT_BATCH_DUMP" || fail "missing 192.0.2.0/24 in coalesced batch"
grep -Fq "tachyon_rule_sec2_subnets { 198.18.0.0/15 }" "$NFT_BATCH_DUMP" || fail "missing sec2 subnets in batch"

# 4. TACHYON_GENERATOR_QUARANTINE_OUT recovers from broken section in-process in a single ucode invocation.
cat >"$UCI_STATE" <<'EOF_GEN_UCI'
tachyon.settings=settings
tachyon.settings.engine=tachyon-core
tachyon.settings.proxy_mode=tproxy
tachyon.good_sec=section
tachyon.good_sec.enabled=1
tachyon.good_sec.action=bypass
tachyon.good_sec.domains=example.com
tachyon.bad_sec=section
tachyon.bad_sec.enabled=1
tachyon.bad_sec.action=connection
tachyon.bad_sec.connection_type=proxy
tachyon.bad_sec.outbound_json={invalid-json
EOF_GEN_UCI

GEN_OUT="$WORK_DIR/config.json"
QUARANTINE_OUT="$WORK_DIR/quarantined.json"

TACHYON_UCI_STATE_FILE="$UCI_STATE" \
  TACHYON_GENERATOR_QUARANTINE_OUT="$QUARANTINE_OUT" \
  ucode -L "$TACHYON_LIB" "$GENERATOR" generate-config "$GEN_OUT" "192.168.1.1" 0 1 2>"$WORK_DIR/gen.err"

[ -s "$GEN_OUT" ] || fail "generator did not produce config.json after in-process quarantine"
[ -s "$QUARANTINE_OUT" ] || fail "generator did not write TACHYON_GENERATOR_QUARANTINE_OUT"
grep -Fq '"section":"bad_sec"' "$QUARANTINE_OUT" || grep -Fq '"section": "bad_sec"' "$QUARANTINE_OUT" || {
  cat "$QUARANTINE_OUT" >&2
  fail "quarantined.json missing bad_sec entry"
}

printf 'NFT reload & generator perf invariants passed\n'
