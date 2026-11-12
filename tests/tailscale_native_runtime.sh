#!/usr/bin/env bash
# Smoke test for providers/tailscale/runtime.uc: runs the real start/stop
# runtime paths against stubbed tailscale/tailscaled binaries and verifies
# every kernel/nftables/dnsmasq side effect appears and is cleaned up.
# Requires a privileged OpenWrt container (ip rule, nft tables).
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

RUNTIME_UC="$TACHYON_LIB/providers/tailscale/runtime.uc"

if [ "$(id -u)" != "0" ]; then
  printf 'skipped: requires root\n'
  exit 0
fi

command -v nft >/dev/null || { printf 'skipped: nft not available\n'; exit 0; }
ip link add tailscale0 type dummy 2>/dev/null ||
  { printf 'skipped: cannot create dummy interface\n'; exit 0; }
ip link set tailscale0 up

TS_LOG="$WORK_DIR/ts.log"

cleanup() {
  PATH="$STUB_BIN:$PATH" ucode -L "$TACHYON_LIB" "$RUNTIME_UC" stop-runtime >/dev/null 2>&1 || true
  ip link del tailscale0 2>/dev/null || true
  rm -rf "$WORK_DIR" "$STATE_FILE"
}
trap cleanup EXIT

STUB_BIN="$WORK_DIR/bin"
mkdir -p "$STUB_BIN"
ip link set tailscale0 up

cat >"$STUB_BIN/tailscaled" <<EOF
#!/bin/sh
printf 'scaled %s\n' "\$*" >> '$TS_LOG'
case "\$*" in
  *--help*) echo " --flag types: netfilter-mode" ;;
  *) exec sleep 3600 ;;
esac
EOF
cat >"$STUB_BIN/tailscale" <<EOF
#!/bin/sh
printf 'cli %s\n' "\$*" >> '$TS_LOG'
case "\$*" in
  *version*) echo "1.80.3-smoke" ;;
  *--json*) cat '$WORK_DIR/ts-status.json' ;;
  *) exit 0 ;;
esac
EOF
cat >"$WORK_DIR/ts-status.json" <<'JSON'
{"BackendState":"Running","Self":{"HostName":"router","DNSName":"router.tailnet.ts.net.","TailscaleIPs":["100.64.0.1"]},"Peer":{"k1":{"HostName":"phone","DNSName":"phone.tailnet.ts.net.","TailscaleIPs":["100.64.0.2"],"Online":true},"k2":{"HostName":"laptop","DNSName":"laptop.tailnet.ts.net.","TailscaleIPs":["100.64.0.3"],"Online":false}}}
JSON
chmod +x "$STUB_BIN/tailscaled" "$STUB_BIN/tailscale"

STATE_FILE="$WORK_DIR/uci.state"
cat >"$STATE_FILE" <<'EOF'
tachyon.settings=settings
tachyon.settings.dns_server=77.88.8.8
tachyon.ts_native=server
tachyon.ts_native.label=Tailscale native
tachyon.ts_native.enabled=1
tachyon.ts_native.protocol=tailscale
tachyon.ts_native.tailscale_mode=native
tachyon.ts_native.routing_mode=rules
tachyon.ts_native.tailscale_auth_key=tskey-auth-smoke
tachyon.ts_native.tailscale_hostname=tachyon-smoke
dhcp.main=dnsmasq
dhcp.main.localservice=1
dhcp.main.cachesize=10000
EOF

export UCI_STATE="$STATE_FILE"
export TACHYON_CONFIG_NAME="tachyon"
export PATH="$STUB_BIN:$PATH"
export TAILSCALED_BIN="$STUB_BIN/tailscaled"
export TAILSCALE_BIN="$STUB_BIN/tailscale"
export TAILSCALE_STATE_BASE="$WORK_DIR/state"
export TAILSCALE_RUNTIME_DIR="$WORK_DIR/run"
export TAILSCALE_DNSMASQ_FILE="$WORK_DIR/dnsmasq.d/tachyon-tailscale.conf"
SERVERS_FILE="$WORK_DIR/etc/dnsmasq-tailscale.servers"
export TAILSCALE_DNSMASQ_SERVERS_FILE="$SERVERS_FILE"

# A dnsmasq restart drops LAN DNS for seconds; a reload with an unchanged
# config is only a SIGHUP. Count both.
DNSMASQ_LOG="$WORK_DIR/dnsmasq-init.log"
cat >"$STUB_BIN/dnsmasq-init" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> '$DNSMASQ_LOG'
EOF
chmod +x "$STUB_BIN/dnsmasq-init"
export DNSMASQ_INIT="$STUB_BIN/dnsmasq-init"
dnsmasq_calls() {
  cat "$DNSMASQ_LOG" 2>/dev/null | grep -c "^$1" || true
}
dhcp_value() {
  sed -n "s/^dhcp\.main\.$1=//p" "$STATE_FILE" | tr -d "'"
}

run() {
  ucode -L "$TACHYON_LIB" "$RUNTIME_UC" "$@"
}

# --- version reporting ------------------------------------------------------
[ "$(run package-version)" = "1.80.3-smoke" ] || fail "package-version output"
run installed || fail "installed must succeed with stubs present"

# --- start ------------------------------------------------------------------
# Fake official init script: must be stopped+disabled before our daemon starts.
INIT_LOG="$WORK_DIR/init.log"
mkdir -p /etc/init.d
cat >"/etc/init.d/tailscale" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> '$INIT_LOG'
exit 0
EOF
chmod +x "/etc/init.d/tailscale"

run start-runtime || fail "start-runtime exited non-zero"
grep -Fq "stop" "$INIT_LOG" || fail "standalone tailscale service was not stopped"
grep -Fq "disable" "$INIT_LOG" || fail "standalone tailscale service was not disabled"

PID_FILE="$WORK_DIR/run/ts_native/tailscaled.pid"
[ -f "$PID_FILE" ] || fail "pid file was not written"
PID="$(cat "$PID_FILE")"
kill -0 "$PID" 2>/dev/null || fail "tailscaled pid is not alive"

grep -Fq "cli --socket $WORK_DIR/run/ts_native/tailscaled.sock up" "$TS_LOG" ||
  fail "tailscale up was not invoked through the section socket"
grep -Fq -e "--authkey=tskey-auth-smoke" "$TS_LOG" ||
  fail "auth key was not passed to tailscale up"
grep -Fq -e "--accept-dns=false" "$TS_LOG" ||
  fail "up must disable tailscaled DNS takeover"
grep -Fq -e "--timeout=120s" "$TS_LOG" ||
  fail "up must carry a hard timeout"

ip rule list | grep -Fq "100.64.0.0/10" || fail "tailnet ip rule missing"
ip rule list | grep -Fq "lookup 4247" || fail "route table rule missing"
[ "$(ip route show table 4247 | grep -cF 'dev tailscale0')" -ge 1 ] ||
  fail "tailnet route missing from table 4247"
nft list table inet tachyon_tailscale >/dev/null 2>&1 ||
  fail "nft table tachyon_tailscale was not created"
nft list table inet tachyon_tailscale | grep -Fq "masquerade" ||
  fail "masquerade rule missing (default on)"
grep -Fq "server=/ts.net/100.100.100.100" "$SERVERS_FILE" ||
  fail "MagicDNS forward entry missing from the dnsmasq servers file"
[ "$(dhcp_value serversfile)" = "$SERVERS_FILE" ] ||
  fail "dnsmasq must read the MagicDNS servers file, got '$(dhcp_value serversfile)'"
[ "$(dhcp_value localservice)" = "0" ] ||
  fail "MagicDNS must let dnsmasq answer tailnet clients (localservice=0)"
[ "$(dhcp_value tachyon_localservice)" = "1" ] ||
  fail "the user's localservice value must be remembered for restore"
[ "$(dnsmasq_calls restart)" = "0" ] && [ "$(dnsmasq_calls reload)" = "1" ] ||
  fail "enabling MagicDNS must reload dnsmasq once and never restart it, got $(cat "$DNSMASQ_LOG")"

STATUS="$(run status)"
printf '%s' "$STATUS" | grep -Fq '"configured": true' ||
  fail "status must report configured=true, got: $STATUS"
printf '%s' "$STATUS" | grep -Fq '"ready": true' ||
  fail "status must report ready=true, got: $STATUS"

PEERS="$(run peers)"
printf '%s' "$PEERS" | grep -Fq '"backend_state": "Running"' ||
  fail "peers must relay backend state, got: $PEERS"
printf '%s' "$PEERS" | grep -Fq '"dns_name": "phone.tailnet.ts.net."' ||
  fail "peers must include tailnet peers, got: $PEERS"
printf '%s' "$PEERS" | grep -Fq '"online": false' ||
  fail "peers must report offline flag, got: $PEERS"

# --- idempotent restart -----------------------------------------------------
run start-runtime || fail "second start-runtime failed"
RULE_COUNT=$(ip rule list | grep -cF "lookup 4247")
[ "$RULE_COUNT" = "1" ] || fail "restart duplicated route rules ($RULE_COUNT)"
[ "$(dnsmasq_calls reload)" = "1" ] ||
  fail "an unchanged MagicDNS config must not touch dnsmasq again, got $(cat "$DNSMASQ_LOG")"

# --- stop -------------------------------------------------------------------
run stop-runtime || fail "stop-runtime exited non-zero"
kill -0 "$PID" 2>/dev/null && fail "tailscaled pid survived stop-runtime"
ip rule list | grep -Fq "100.64.0.0/10" && fail "tailnet ip rule survived stop"
ip route show table 4247 | grep -q . && fail "route table 4247 survived stop"
nft list table inet tachyon_tailscale >/dev/null 2>&1 &&
  fail "nft table survived stop"
[ -f "$WORK_DIR/dnsmasq.d/tachyon-tailscale.conf" ] &&
  fail "dnsmasq config survived stop"
# Service stop (procd runs it on every reboot) empties the servers file and
# keeps the dhcp options, so neither stop nor the next start restarts dnsmasq.
[ -s "$SERVERS_FILE" ] && fail "service stop must empty the MagicDNS servers file"
[ "$(dhcp_value serversfile)" = "$SERVERS_FILE" ] ||
  fail "service stop must keep the dnsmasq servers file option"
[ "$(dnsmasq_calls restart)" = "0" ] && [ "$(dnsmasq_calls reload)" = "2" ] ||
  fail "service stop must only reload dnsmasq, got $(cat "$DNSMASQ_LOG")"
run stop-runtime || fail "repeated stop-runtime exited non-zero"
[ "$(dnsmasq_calls reload)" = "2" ] ||
  fail "repeated stop-runtime must not touch dnsmasq, got $(cat "$DNSMASQ_LOG")"

# --- exit node mode ---------------------------------------------------------
printf '%s\n' 'tachyon.ts_native.tailscale_use_exit_node=1' >>"$STATE_FILE"
run start-runtime || fail "start-runtime with exit node failed"
ip rule list | grep -Fq "lookup 4248" || fail "exit-node ip rule missing"
[ "$(ip route show table 4248 | grep -cF 'default dev tailscale0')" = "1" ] ||
  fail "exit-node default route missing"
nft list chain inet tachyon_tailscale prerouting_mark >/dev/null 2>&1 ||
  fail "exit-node marking chain missing"
nft list set inet tachyon_tailscale exit_exclude_v4 | grep -Fq "198.18.0.0/15" ||
  fail "exit_exclude_v4 must exclude FakeIP 198.18.0.0/15 range (#318)"
run stop-runtime || fail "stop-runtime after exit node failed"
ip rule list | grep -Fq "lookup 4248" && fail "exit-node rule survived stop"

# --- tailnet removed: dhcp goes back to the user's values --------------------
sed -i '/^tachyon\.ts_native/d' "$STATE_FILE"
run start-runtime || fail "start-runtime without a tailnet failed"
[ -z "$(dhcp_value serversfile)" ] || fail "servers file option survived tailnet removal"
[ "$(dhcp_value localservice)" = "1" ] || fail "user's localservice=1 was not restored"
grep -q '^dhcp\.main\.tachyon_' "$STATE_FILE" && fail "tachyon_* markers survived tailnet removal"
[ "$(dhcp_value cachesize)" = "10000" ] || fail "unrelated dnsmasq options must stay untouched"
[ -e "$SERVERS_FILE" ] && fail "MagicDNS servers file survived tailnet removal"
[ "$(dnsmasq_calls restart)" = "0" ] || fail "tailnet removal must not restart dnsmasq directly"
RELOADS="$(dnsmasq_calls reload)"
run start-runtime || fail "repeated start-runtime without a tailnet failed"
[ "$(dnsmasq_calls reload)" = "$RELOADS" ] ||
  fail "every reload without a tailnet must leave dnsmasq alone, got $(cat "$DNSMASQ_LOG")"

# --- a servers file the user set in LuCI is never taken over ----------------
printf '%s\n' 'tachyon.ts_native=server' 'tachyon.ts_native.enabled=1' \
  'tachyon.ts_native.protocol=tailscale' 'tachyon.ts_native.tailscale_mode=native' \
  'tachyon.ts_native.tailscale_auth_key=tskey-auth-smoke' \
  'dhcp.main.serversfile=/etc/user-dnsmasq.servers' >>"$STATE_FILE"
run start-runtime || true
[ "$(dhcp_value serversfile)" = "/etc/user-dnsmasq.servers" ] ||
  fail "the user's own dnsmasq servers file must stay untouched"
[ "$(dhcp_value localservice)" = "1" ] ||
  fail "dhcp must stay untouched when the servers file belongs to the user"
run stop-runtime || true

printf 'tailscale native runtime smoke checks passed\n'
