#!/usr/bin/env bash
# Regression test for issue #546:
# When a section recovers from fail_policy while reload lock is held by another
# process, the deferred section_fail_policy reload must not lose its reason or
# leave section routing stuck on the fail policy after the lock is released.

. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

FAILOVER_UC="$TACHYON_LIB/service/failover.uc"
LIFECYCLE_UC="$TACHYON_LIB/service/lifecycle.uc"
STATE_UC="$TACHYON_LIB/service/state.uc"

BG_PIDS=()
cleanup_bg() {
  for p in "${BG_PIDS[@]:-}"; do
    kill "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  done
}
trap cleanup_bg EXIT

# ---------------------------------------------------------------------------
# 1. lifecycle.uc reload section_fail_policy returns exit 75 and preserves
#    reason=section_fail_policy in PENDING_RELOAD_FILE when reload lock is busy.
# ---------------------------------------------------------------------------
FAKE_BIN="$WORK_DIR/fake_bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/logger" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKE_BIN/logger"

LOCK_DIR="$WORK_DIR/reload.lock"
PENDING_FILE="$WORK_DIR/reload.pending"
FAIL_STATE_FILE="$WORK_DIR/section-fail-state.json"
FAIL_PENDING_FILE="$FAIL_STATE_FILE.reload-pending"

ucode -e 'sleep(30000);' &
lock_owner=$!
BG_PIDS+=("$lock_owner")
mkdir -p "$LOCK_DIR"
printf '%s\n' "$lock_owner" >"$LOCK_DIR/pid"

set +e
TACHYON_LIB="$TACHYON_LIB" \
TACHYON_RELOAD_LOCK_DIR="$LOCK_DIR" \
TACHYON_PENDING_RELOAD_FILE="$PENDING_FILE" \
TACHYON_SECTION_FAIL_STATE_FILE="$FAIL_STATE_FILE" \
TACHYON_SECTION_FAIL_RELOAD_PENDING_FILE="$FAIL_PENDING_FILE" \
PATH="$FAKE_BIN:$PATH" \
  ucode -L "$TACHYON_LIB" "$LIFECYCLE_UC" reload section_fail_policy
reload_busy_rc=$?
set -e

[ "$reload_busy_rc" = "75" ] ||
  fail "expected exit code 75 for deferred section_fail_policy reload, got $reload_busy_rc"
[ -f "$PENDING_FILE" ] && grep -Fxq 'reason=section_fail_policy' "$PENDING_FILE" ||
  fail "expected PENDING_RELOAD_FILE to contain reason=section_fail_policy"

ucode -L "$TACHYON_LIB" "$STATE_UC" release-runtime-dir-lock "$LOCK_DIR" "$lock_owner"
kill "$lock_owner" 2>/dev/null || true
wait "$lock_owner" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. state.uc run-pending-reload-if-requested preserves section_fail_policy arg
# ---------------------------------------------------------------------------
INIT_CALL_LOG="$WORK_DIR/init-calls.log"
FAKE_INIT="$WORK_DIR/fake-init.sh"
cat >"$FAKE_INIT" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$INIT_CALL_LOG'
exit 0
EOF
chmod +x "$FAKE_INIT"

rm -f "$INIT_CALL_LOG"
ucode -L "$TACHYON_LIB" "$STATE_UC" run-pending-reload-if-requested "$PENDING_FILE" "$FAKE_INIT"

attempts=0
while [ ! -s "$INIT_CALL_LOG" ] && [ "$attempts" -lt 30 ]; do
  sleep 0.1
  attempts=$((attempts + 1))
done
grep -Fxq 'reload section_fail_policy' "$INIT_CALL_LOG" ||
  fail "expected run-pending-reload-if-requested to invoke 'reload section_fail_policy', got: $(cat "$INIT_CALL_LOG" 2>/dev/null || echo missing)"

# ---------------------------------------------------------------------------
# 3. End-to-end failover.uc 3-step recovery retry across busy lock:
#    Step 1: section fails -> failed=true, reload rc=0
#    Step 2: section recovers while reload lock is held -> failed=false, reload rc=75 -> .reload-pending written
#    Step 3: lock released, next check has no state transition -> retries reload section_fail_policy -> rc=0 -> clears .reload-pending
#    Step 4: steady check -> does not trigger extra reload
# ---------------------------------------------------------------------------
STUB_BIN="$WORK_DIR/stub_bin"
mkdir -p "$STUB_BIN"
PROBE_LOG="$WORK_DIR/probe.log"
RELOAD_LOG="$WORK_DIR/reload.log"
MOCK_RELOAD_RC_FILE="$WORK_DIR/mock_reload_rc"
printf '0\n' >"$MOCK_RELOAD_RC_FILE"

cat >"$STUB_BIN/tachyon" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "reload" ]; then
  printf '%s\n' "\$*" >> '$RELOAD_LOG'
  rc=\$(tr -d '[:space:]' < '$MOCK_RELOAD_RC_FILE')
  exit "\${rc:-0}"
fi
printf '%s\n' "\$*" >> '$PROBE_LOG'
case "\$*" in
  *"get_proxy_latency zap_sec-out"*)
    if [ "\${ZAP_DEAD:-0}" = "1" ]; then echo '{"error":"timeout"}'; else echo '{"delay":42}'; fi ;;
  *"get_proxy_latency direct-out"*)
    echo '{"delay":18}' ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$STUB_BIN/tachyon"

cat >"$WORK_DIR/uci.state" <<'EOF'
tachyon.settings=settings
tachyon.settings.section_failover_enabled=0
tachyon.settings.section_failover_threshold=3
tachyon.zap_sec=section
tachyon.zap_sec.enabled=1
tachyon.zap_sec.action=desync
tachyon.zap_sec.desync_preset=auto
tachyon.zap_sec.fail_policy=block
tachyon.zap_sec.fail_policy_urls=https://i.ytimg.com/generate_204
tachyon.zap_sec.fail_policy_timeout=2500
tachyon.zap_sec.fail_policy_threshold=1
tachyon.zap_sec.fail_policy_recover_threshold=1
tachyon.zap_sec.fail_policy_check_direct=0
EOF

rm -f "$FAIL_STATE_FILE" "$FAIL_PENDING_FILE" "$RELOAD_LOG" "$PROBE_LOG"

run_failover_step() {
  UCI_STATE="$WORK_DIR/uci.state" \
  TACHYON_BIN="$STUB_BIN/tachyon" \
  TACHYON_SECTION_FAIL_STATE_FILE="$FAIL_STATE_FILE" \
  TACHYON_SECTION_FAIL_RELOAD_PENDING_FILE="$FAIL_PENDING_FILE" \
  PATH="$FAKE_BIN:$PATH" \
    ucode -L "$TACHYON_LIB" "$FAILOVER_UC" check
}

# Step 1: enter fail policy (reload succeeds)
printf '0\n' >"$MOCK_RELOAD_RC_FILE"
ZAP_DEAD=1 run_failover_step
grep -Fq '"failed": true' "$FAIL_STATE_FILE" || fail "step 1: section must transition to failed=true"
[ "$(wc -l <"$RELOAD_LOG" | tr -d '[:space:]')" = "1" ] || fail "step 1: expected 1 reload invocation"
[ ! -f "$FAIL_PENDING_FILE" ] || fail "step 1: pending reload marker must not exist after rc=0"

# Step 2: recover while reload lock is busy (reload returns 75)
printf '75\n' >"$MOCK_RELOAD_RC_FILE"
ZAP_DEAD=0 run_failover_step
grep -Fq '"failed": false' "$FAIL_STATE_FILE" || fail "step 2: section must transition to failed=false"
[ "$(wc -l <"$RELOAD_LOG" | tr -d '[:space:]')" = "2" ] || fail "step 2: expected 2nd reload attempt on recovery"
[ -f "$FAIL_PENDING_FILE" ] || fail "step 2: pending reload marker must be created after deferred rc=75"

# Step 3: lock released, no state change -> retries reload and clears marker
printf '0\n' >"$MOCK_RELOAD_RC_FILE"
ZAP_DEAD=0 run_failover_step
[ "$(wc -l <"$RELOAD_LOG" | tr -d '[:space:]')" = "3" ] || fail "step 3: must retry reload section_fail_policy when marker is present"
grep -Fxq 'reload section_fail_policy' "$RELOAD_LOG" || fail "step 3: expected 'reload section_fail_policy' calls"
[ ! -f "$FAIL_PENDING_FILE" ] || fail "step 3: pending reload marker must be removed after rc=0"

# Step 4: steady check does not trigger redundant reload
ZAP_DEAD=0 run_failover_step
[ "$(wc -l <"$RELOAD_LOG" | tr -d '[:space:]')" = "3" ] || fail "step 4: must not reload again once pending marker is cleared"

printf 'section_fail_policy_lock_busy: OK\n'
