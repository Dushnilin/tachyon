#!/usr/bin/env bash
# FAULT: every configured DNS resolver is dead.
#
# The point of the failover worker is to tell the user when resolution is dead,
# and the flag it reports that through is choose_index()'s `alive`. The one case
# it used to get wrong is the smallest configuration there is: a single server.
# There is nothing to fail over to, so the index cannot change - but "nothing to
# switch to" is not "working", and it returned alive:true without probing. A user
# with one resolver, whose resolver is down, got silence.
#
# It also means the answer depended on how many servers were configured: the
# same physical condition, no working DNS, was reported differently at one
# server and at two.
#
# This drives the real decision through the select-fixture CLI, which now calls
# choose_index rather than reimplementing it.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"
FAILOVER="$LIB_DIR/singbox/dns_failover.uc"

[ -f "$FAILOVER" ] || fail "singbox/dns_failover.uc not found"

trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM

pick() {
  ucode -L "$LIB_DIR" "$FAILOVER" select-fixture "$1" "$2" "$3" "${4:-0}" 2>&1
}

field() { printf '%s' "$1" | tr ',' '\n' | grep -F "\"$2\":" | sed 's/.*: *//; s/[{}]//g; s/[\"]//g; s/^ *//; s/ *$//'; }

# --- one server, dead: must be reported dead -------------------------------
echo '{"main_servers":["9.9.9.9"],"main_index":0}' > "$WORK_DIR/one.json"
echo '{"0":false}' > "$WORK_DIR/one-dead.json"

out="$(pick "$WORK_DIR/one.json" "$WORK_DIR/one-dead.json" main)" \
  || fail "select-fixture failed on a single dead server: $out"

[ "$(field "$out" index)" = "0" ] \
  || fail "a single dead server must keep its index, there is nowhere to switch: $out"
[ "$(field "$out" alive)" = "false" ] \
  || fail "a single dead DNS server was reported alive - the user is left with silence and no working DNS: $out"

# --- one server, alive: unchanged ------------------------------------------
echo '{"0":true}' > "$WORK_DIR/one-alive.json"
out="$(pick "$WORK_DIR/one.json" "$WORK_DIR/one-alive.json" main)" \
  || fail "select-fixture failed on a single live server: $out"
[ "$(field "$out" alive)" = "true" ] || fail "a working single server was reported dead: $out"
[ "$(field "$out" index)" = "0" ] || fail "a working single server changed index: $out"

# --- the asymmetry the old code hid: same condition, different config ------
# Two servers, both dead, is the case that was already handled. Asserting both
# is what pins that the single-server answer now agrees with it.
cat > "$WORK_DIR/two.json" <<'EOF'
{"main_servers":["9.9.9.9","1.1.1.1"],"main_index":0}
EOF
echo '{"0":false,"1":false}' > "$WORK_DIR/two-dead.json"
out="$(pick "$WORK_DIR/two.json" "$WORK_DIR/two-dead.json" main)" \
  || fail "select-fixture failed on two dead servers: $out"
[ "$(field "$out" alive)" = "false" ] \
  || fail "two dead servers were reported alive: $out"
[ "$(field "$out" reason)" = "all_down" ] \
  || fail "two dead servers gave the wrong reason: $out"

# --- one dead bootstrap alongside healthy main -----------------------------
# The worker only stands down when BOTH lists are a single server, so this
# configuration is one it really does supervise, and a dead bootstrap in it has
# to surface the same way.
cat > "$WORK_DIR/boot.json" <<'EOF'
{"main_servers":["9.9.9.9","1.1.1.1"],"main_index":0,"bootstrap_servers":["8.8.8.8"],"bootstrap_index":0}
EOF
out="$(pick "$WORK_DIR/boot.json" "$WORK_DIR/one-dead.json" bootstrap)" \
  || fail "select-fixture failed on a dead single bootstrap: $out"
[ "$(field "$out" alive)" = "false" ] \
  || fail "a dead single bootstrap resolver was reported alive while main was healthy: $out"

# --- a mixed list must still fail over, unchanged by the above -------------
# Guards against the single-server branch swallowing the multi-server path.
echo '{"0":false,"1":true}' > "$WORK_DIR/two-mixed.json"
out="$(pick "$WORK_DIR/two.json" "$WORK_DIR/two-mixed.json" main)" \
  || fail "select-fixture failed on a mixed list: $out"
[ "$(field "$out" index)" = "1" ] || fail "failover did not move off the dead server: $out"
[ "$(field "$out" alive)" = "true" ] || fail "a working alternative was not adopted: $out"

printf 'fault: DNS resolver exhaustion checks passed\n'
