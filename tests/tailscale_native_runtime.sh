#!/usr/bin/env bash
# Smoke test for providers/tailscale/runtime.uc: runs the real start/stop
# runtime paths against stubbed tailscale/tailscaled binaries and verifies
# every kernel/nftables/dnsmasq side effect appears and is cleaned up.
# Requires a privileged OpenWrt container (ip rule, nft tables).
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
RUNTIME_UC="$TACHYON_LIB/providers/tailscale/runtime.uc"

if [ "$(id -u)" != "0" ]; then
  printf 'skipped: requires root\n'
  exit 0
fi

command -v nft >/dev/null || { printf 'skipped: nft not available\n'; exit 0; }
ip link add tailscale0 type dummy 2>/dev/null ||
  { printf 'skipped: cannot create dummy interface\n'; exit 0; }
ip link set tailscale0 up

WORK_DIR="$(mktemp -d)"
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
exec sleep 3600
EOF
cat >"$STUB_BIN/tailscale" <<EOF
#!/bin/sh
printf 'cli %s\n' "\$*" >> '$TS_LOG'
case "\$*" in
  *version*) echo "1.80.3-smoke" ;;
  *) exit 0 ;;
esac
EOF
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
EOF

export UCI_STATE="$STATE_FILE"
export TACHYON_CONFIG_NAME="tachyon"
export PATH="$STUB_BIN:$PATH"
export TAILSCALED_BIN="$STUB_BIN/tailscaled"
export TAILSCALE_BIN="$STUB_BIN/tailscale"
export TAILSCALE_STATE_BASE="$WORK_DIR/state"
export TAILSCALE_RUNTIME_DIR="$WORK_DIR/run"
export TAILSCALE_DNSMASQ_FILE="$WORK_DIR/dnsmasq.d/tachyon-tailscale.conf"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

run() {
  ucode -L "$TACHYON_LIB" "$RUNTIME_UC" "$@"
}

# --- version reporting ------------------------------------------------------
[ "$(run package-version)" = "1.80.3-smoke" ] || fail "package-version output"
run installed || fail "installed must succeed with stubs present"

# --- start ------------------------------------------------------------------
run start-runtime || fail "start-runtime exited non-zero"

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
[ -f "$WORK_DIR/dnsmasq.d/tachyon-tailscale.conf" ] ||
  fail "MagicDNS dnsmasq config was not written"
grep -Fq "server=/ts.net/100.100.100.100" \
  "$WORK_DIR/dnsmasq.d/tachyon-tailscale.conf" ||
  fail "MagicDNS forward entry missing"

STATUS="$(run status)"
printf '%s' "$STATUS" | grep -Fq '"configured": true' ||
  fail "status must report configured=true, got: $STATUS"
printf '%s' "$STATUS" | grep -Fq '"ready": true' ||
  fail "status must report ready=true, got: $STATUS"

# --- idempotent restart -----------------------------------------------------
run start-runtime || fail "second start-runtime failed"
RULE_COUNT=$(ip rule list | grep -cF "lookup 4247")
[ "$RULE_COUNT" = "1" ] || fail "restart duplicated route rules ($RULE_COUNT)"

# --- stop -------------------------------------------------------------------
run stop-runtime || fail "stop-runtime exited non-zero"
kill -0 "$PID" 2>/dev/null && fail "tailscaled pid survived stop-runtime"
ip rule list | grep -Fq "100.64.0.0/10" && fail "tailnet ip rule survived stop"
ip route show table 4247 | grep -q . && fail "route table 4247 survived stop"
nft list table inet tachyon_tailscale >/dev/null 2>&1 &&
  fail "nft table survived stop"
[ -f "$WORK_DIR/dnsmasq.d/tachyon-tailscale.conf" ] &&
  fail "dnsmasq config survived stop"

# --- exit node mode ---------------------------------------------------------
printf '%s\n' 'tachyon.ts_native.tailscale_use_exit_node=1' >>"$STATE_FILE"
run start-runtime || fail "start-runtime with exit node failed"
ip rule list | grep -Fq "lookup 4248" || fail "exit-node ip rule missing"
[ "$(ip route show table 4248 | grep -cF 'default dev tailscale0')" = "1" ] ||
  fail "exit-node default route missing"
nft list chain inet tachyon_tailscale prerouting_mark >/dev/null 2>&1 ||
  fail "exit-node marking chain missing"
run stop-runtime || fail "stop-runtime after exit node failed"
ip rule list | grep -Fq "lookup 4248" && fail "exit-node rule survived stop"

printf 'tailscale native runtime smoke checks passed\n'
