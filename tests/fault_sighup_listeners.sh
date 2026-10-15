#!/usr/bin/env bash
# FAULT: a SIGHUP that comes back deaf must not be reported as a successful reload.
#
# Observed on a live router running tachyon-core: DNS failover rewrote config.json
# and sent SIGHUP; sing-box accepted it, kept the same pid, and kept answering the
# clash API - while the mixed inbound simply never came back. Port 4534 vanished,
# every LAN client proxy and the Telegram bot dead-ended, and try_sighup_reload()
# logged "graceful reload succeeded" because it only asked whether the process was
# still alive. Only watchdog.uc's two-strike mixed-port watch noticed, ten minutes
# later; `tachyon reload force` returned 0 and changed nothing.
#
# A live pid is not evidence that a reload worked. The ports the generated config
# promises have to be in LISTEN before the reload counts, and a deaf reload has to
# fall through to the full-restart escalation the caller already has.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

STATE_UC="$TACHYON_LIB/service/state.uc"
UCODE_BIN="$(command -v ucode)"
[ -f "$STATE_UC" ] || fail "service/state.uc not found"

DEAD_PORT=45999
mkdir -p "$WORK_DIR/bin"
cp /bin/sleep "$WORK_DIR/bin/tachyon-core"

cleanup_extra() {
  [ -n "${FAKE_PID:-}" ] && kill "$FAKE_PID" 2>/dev/null
  release_core_proc_lock
  return 0
}
trap 'cleanup_extra; cleanup' EXIT

# fault_verify_system_dead_engine.sh asserts that no process called tachyon-core is
# running, which this stand-in violates by construction.
acquire_core_proc_lock

# A stand-in that is the core to process_identity (exe basename and comm are
# both "tachyon-core") but survives the SIGHUP it is sent. Without the trap the
# process would die on HUP and every assertion below would pass for the wrong
# reason - the pid check, not the listener check, would have decided.
( trap '' HUP; exec "$WORK_DIR/bin/tachyon-core" 120 ) &
FAKE_PID=$!
sleep 1
[ "$(cat "/proc/$FAKE_PID/comm" 2>/dev/null)" = "tachyon-core" ] ||
  fail "fake core is not identifiable as the core (comm mismatch)"
kill -0 "$FAKE_PID" 2>/dev/null || fail "fake core did not start"

write_config() {
  cat >"$WORK_DIR/tachyon-core.json" <<JSON
{
  "inbounds": $1,
  "outbounds": []
}
JSON
  printf 'tachyon.settings.config_path=%s\n' "$WORK_DIR/tachyon-core.json" \
    >"$WORK_DIR/uci.state"
}

sighup_rc() {
  set +e
  TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state" \
    "$UCODE_BIN" -L "$TACHYON_LIB" "$STATE_UC" sighup-core-runtime "$FAKE_PID" \
    >/dev/null 2>&1
  local rc=$?
  set -e
  return $rc
}

# --- control: with no mixed inbound there is nothing to prove, so a live pid
# --- is the whole contract. This also proves the harness can find the process,
# --- which is what makes the next case meaningful.
write_config '[]'
sighup_rc ||
  fail "SIGHUP must succeed when the config declares no mixed inbound (harness cannot see the process, or the pid check is broken)"
kill -0 "$FAKE_PID" 2>/dev/null ||
  fail "fake sing-box must survive SIGHUP; without that the next case proves nothing"

# --- the regression: mixed inbound declared, nothing listening on it ---------
write_config "[ { \"type\": \"mixed\", \"listen_port\": $DEAD_PORT } ]"
if sighup_rc; then
  fail "SIGHUP reported success while the declared mixed port $DEAD_PORT was not listening - that is the silent proxy loss from this bug"
fi
kill -0 "$FAKE_PID" 2>/dev/null ||
  fail "fake sing-box died during the port check; the failure came from the pid check, not the listener check, so the case proves nothing"

# --- the positive contract: mixed inbound declared and port is actually listening
LIVE_PORT=45998
node -e "require('net').createServer().listen($LIVE_PORT); setInterval(()=>{}, 1000);" &
NODE_PID=$!
sleep 0.5
write_config "[ { \"type\": \"mixed\", \"listen_port\": $LIVE_PORT } ]"
if ! sighup_rc; then
  kill "$NODE_PID" 2>/dev/null || true
  fail "SIGHUP must succeed when declared mixed port $LIVE_PORT is listening"
fi
kill "$NODE_PID" 2>/dev/null || true


# --- the success path has to consult the listeners too, not just the loop exit
awk '/^function try_sighup_reload\(/,/^}/' "$STATE_UC" >"$WORK_DIR/sighup.uc"
[ -s "$WORK_DIR/sighup.uc" ] || fail "try_sighup_reload not found in service/state.uc"
[ "$(grep -c 'sing_box_mixed_ports_listening' "$WORK_DIR/sighup.uc")" -ge 2 ] ||
  fail "try_sighup_reload must check the listeners on both the poll-success and the timeout path; a deaf core would otherwise still pass the timeout branch"

# Reading the ports out of the generated config rather than hardcoding 4534 is
# what keeps this honest when a section disables the mixed proxy entirely.
grep -Fq 'config_path' "$STATE_UC" ||
  fail "the mixed-port lookup must follow the configured config_path"
grep -Fq 'inbound.type != "mixed"' "$STATE_UC" ||
  fail "the mixed-port lookup must select inbound type mixed out of the generated config"

printf 'SIGHUP listener verification checks passed\n'