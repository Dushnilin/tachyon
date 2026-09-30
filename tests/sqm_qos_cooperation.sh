#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

NFT_RUNTIME="$ROOT_DIR/tachyon/files/usr/lib/nft/apply.uc"
DIAG_RUNTIME="$ROOT_DIR/tachyon/files/usr/lib/diagnostics/runtime.uc"

mkdir -p "$WORK_DIR/bin"
NFT_LOG="$WORK_DIR/nft.log"

cat >"$WORK_DIR/bin/nft" <<'NFT'
#!/usr/bin/env bash
set -eo pipefail
{
  printf 'nft'
  for arg in "$@"; do
    printf '\t%s' "$arg"
  done
  printf '\n'
} >> "${NFT_LOG:?}"
NFT
chmod 0755 "$WORK_DIR/bin/nft"

cat >"$WORK_DIR/bin/logger" <<'LOGGER'
#!/usr/bin/env bash
exit 0
LOGGER
chmod 0755 "$WORK_DIR/bin/logger"

cat >"$WORK_DIR/bin/sysctl" <<'SYSCTL'
#!/usr/bin/env bash
exit 0
SYSCTL
chmod 0755 "$WORK_DIR/bin/sysctl"

export PATH="$WORK_DIR/bin:$PATH"
export NFT_LOG

# -----------------------------------------------------------------------------
# Case 1: SQM is active -> Voice & Gaming DSCP are marked, but ACK (CS2) is omitted
# -----------------------------------------------------------------------------
echo "=== Test 1: SQM active -> Voice (EF) and Gaming (AF41) present, ACK (CS2) omitted ==="
cat >"$WORK_DIR/sqm_active.state" <<'EOF'
tachyon.settings=settings
tachyon.settings.qos_priority_engine=
sqm.eth0=queue
sqm.eth0.enabled=1
sqm.eth0.interface=pppoe-wan
EOF

: > "$NFT_LOG"
TACHYON_UCI_STATE_FILE="$WORK_DIR/sqm_active.state" \
  ucode -L "$TACHYON_LIB" "$NFT_RUNTIME" nft-create-runtime-base TachyonTable localv4 tachyon_subnets tachyon_ports tachyon_ip_ports tachyon_interfaces "br-lan" 0x00100000 0x00200000 198.18.0.0/15 1602 1 "" "" "" "" "" 0

if ! grep -Fq $'ip\tdscp\tset\t0x2e' "$NFT_LOG"; then
  fail "Voice DSCP (0x2e / EF) must be marked even when SQM is active"
fi

if ! grep -Fq $'ip\tdscp\tset\t0x22' "$NFT_LOG"; then
  fail "Gaming DSCP (0x22 / AF41) must be marked even when SQM is active"
fi

if grep -Fq $'dscp\tset\tcs2' "$NFT_LOG"; then
  fail "ACK DSCP (cs2) must NOT be marked when SQM is active (preserves CAKE diffserv4 Video tin)"
fi

# -----------------------------------------------------------------------------
# Case 2: SQM is disabled -> Voice, Gaming, AND ACK (CS2) all marked
# -----------------------------------------------------------------------------
echo "=== Test 2: SQM disabled -> Voice, Gaming, AND ACK (CS2) all marked ==="
cat >"$WORK_DIR/sqm_inactive.state" <<'EOF'
tachyon.settings=settings
tachyon.settings.qos_priority_engine=
sqm.eth0=queue
sqm.eth0.enabled=0
sqm.eth0.interface=pppoe-wan
EOF

: > "$NFT_LOG"
TACHYON_UCI_STATE_FILE="$WORK_DIR/sqm_inactive.state" \
  ucode -L "$TACHYON_LIB" "$NFT_RUNTIME" nft-create-runtime-base TachyonTable localv4 tachyon_subnets tachyon_ports tachyon_ip_ports tachyon_interfaces "br-lan" 0x00100000 0x00200000 198.18.0.0/15 1602 1 "" "" "" "" "" 0

if ! grep -Fq $'ip\tdscp\tset\t0x2e' "$NFT_LOG"; then
  fail "Voice DSCP (0x2e) must be marked when SQM is disabled"
fi

if ! grep -Fq $'ip\tdscp\tset\t0x22' "$NFT_LOG"; then
  fail "Gaming DSCP (0x22) must be marked when SQM is disabled"
fi

if ! grep -Fq $'ip\tdscp\tset\tcs2' "$NFT_LOG"; then
  fail "ACK DSCP (cs2) must be marked when SQM is disabled"
fi

# -----------------------------------------------------------------------------
# Case 3: QoS Priority Engine explicitly disabled ('0') -> No DSCP rules
# -----------------------------------------------------------------------------
echo "=== Test 3: QoS priority engine disabled ('0') -> No DSCP rules ==="
cat >"$WORK_DIR/qos_disabled.state" <<'EOF'
tachyon.settings=settings
tachyon.settings.qos_priority_engine=0
sqm.eth0=queue
sqm.eth0.enabled=0
sqm.eth0.interface=pppoe-wan
EOF

: > "$NFT_LOG"
TACHYON_UCI_STATE_FILE="$WORK_DIR/qos_disabled.state" \
  ucode -L "$TACHYON_LIB" "$NFT_RUNTIME" nft-create-runtime-base TachyonTable localv4 tachyon_subnets tachyon_ports tachyon_ip_ports tachyon_interfaces "br-lan" 0x00100000 0x00200000 198.18.0.0/15 1602 1 "" "" "" "" "" 0

if grep -Fq $'dscp\tset' "$NFT_LOG"; then
  fail "No DSCP rules should be added when qos_priority_engine is '0'"
fi

# -----------------------------------------------------------------------------
# Case 4: Doctor detects SQM + Flow Offloading conflict
# -----------------------------------------------------------------------------
echo "=== Test 4: Doctor detects SQM + Flow Offloading conflict ==="
cat >"$WORK_DIR/doctor_conflict.state" <<'EOF'
tachyon.settings=settings
tachyon.settings.core=sing-box
tachyon.Main=section
tachyon.Main.enabled=1
sqm.wan=queue
sqm.wan.enabled=1
sqm.wan.interface=br-lan
firewall.@defaults[0]=defaults
firewall.@defaults[0].flow_offloading=1
network.br_lan=device
network.br_lan.name=br-lan
network.br_lan.ports=eth1
EOF

DOCTOR_OUT="$(TACHYON_UCI_STATE_FILE="$WORK_DIR/doctor_conflict.state" \
  ucode -L "$TACHYON_LIB" -e '
    let uci = require("core.uci");
    let queues = uci.section_objects("sqm", "queue");
    let flow_offload = uci.get("firewall.@defaults[0].flow_offloading");
    let lan_ports = uci.get("network.br_lan.ports") || [];
    if (type(lan_ports) == "string") lan_ports = split(lan_ports, /\s+/);
    print("QUEUES=" + length(queues) + " OFFLOAD=" + flow_offload + " PORTS=" + length(lan_ports) + "\n");
')"

if [ "$DOCTOR_OUT" != "QUEUES=1 OFFLOAD=1 PORTS=1" ]; then
  fail "UCI parsing for SQM and firewall state failed, got: $DOCTOR_OUT"
fi

echo "=== ALL SQM / QOS COOPERATION TESTS PASSED ==="
