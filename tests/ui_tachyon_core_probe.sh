#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -euo pipefail

UI_UC="$TACHYON_LIB/service/ui.uc"
PROBE_BIN="$WORK_DIR/tachyon-core"
PROBE_COUNT="$WORK_DIR/probe-count"
PROBE_PIDS="$WORK_DIR/probe-pids"
CACHE_FILE="$WORK_DIR/tachyon-core-version-cache"

cleanup() {
  if [ -f "$PROBE_PIDS" ]; then
    while IFS= read -r pid; do
      kill -9 "$pid" 2>/dev/null || true
    done <"$PROBE_PIDS"
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

cat >"$PROBE_BIN" <<'SH'
#!/bin/sh
printf '%s\n' "$$" >>"$TACHYON_TEST_CORE_PROBE_PIDS"
printf 'probe\n' >>"$TACHYON_TEST_CORE_PROBE_COUNT"
if [ "${TACHYON_TEST_CORE_PROBE_MODE:-fast}" = "slow" ]; then
  exec sleep 30
fi
printf 'tachyon-core version 0.5.7\n\n'
printf 'Tags: with_quic,with_tailscale\n'
SH
chmod 755 "$PROBE_BIN"
cat >"$WORK_DIR/opkg" <<'SH'
#!/bin/sh
exit 0
SH
chmod 755 "$WORK_DIR/opkg"

ui_capabilities() {
  PATH="$WORK_DIR:$PATH" \
  TACHYON_CONFIG_NAME=tachyon-ui-probe-test \
  TACHYON_UI_STATE_DIR="$WORK_DIR/state" \
  TACHYON_UI_COMPONENT_ACTION_DIR="$WORK_DIR/components" \
  TACHYON_UI_CORE_VERSION_CACHE_FILE="$CACHE_FILE" \
  TACHYON_UI_CORE_BIN_PATH="$PROBE_BIN" \
  TACHYON_UI_CORE_VERSION_PROBE_TIMEOUT_SECONDS=1 \
  TACHYON_UI_CORE_VERSION_PROBE_FAILURE_TTL_SECONDS=30 \
  ZAPRET_PROVIDER_NFQWS_BIN="$WORK_DIR/missing-nfqws" \
  ZAPRET2_PROVIDER_NFQWS2_BIN="$WORK_DIR/missing-nfqws2" \
  BYEDPI_BIN="$WORK_DIR/missing-ciadpi" \
  TACHYON_TEST_CORE_PROBE_COUNT="$PROBE_COUNT" \
  TACHYON_TEST_CORE_PROBE_PIDS="$PROBE_PIDS" \
  ucode -L "$TACHYON_LIB" "$UI_UC" get-ui-capabilities
}

fast_first="$(TACHYON_TEST_CORE_PROBE_MODE=fast ui_capabilities)"
fast_second="$(TACHYON_TEST_CORE_PROBE_MODE=fast ui_capabilities)"
[ "$(wc -l <"$PROBE_COUNT")" -eq 1 ] ||
  fail "successful tachyon-core capability detection must be cached by binary signature"

JSON_VALUE="$fast_first" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (value.tachyon_core_tailscale !== 1) {
  console.error('cached tachyon-core capability flags mismatch:', value);
  process.exit(1);
}
NODE
[ "$fast_first" = "$fast_second" ] ||
  fail "cached tachyon-core capabilities must match the initial detection"

: >"$PROBE_COUNT"
: >"$PROBE_PIDS"
rm -rf "$CACHE_FILE" "$CACHE_FILE.lock"

start_seconds=$SECONDS
workers=""
for index in 1 2 3 4 5; do
  TACHYON_TEST_CORE_PROBE_MODE=slow ui_capabilities >"$WORK_DIR/slow-$index.json" &
  workers="$workers $!"
done
for worker in $workers; do
  wait "$worker"
done
elapsed_seconds=$((SECONDS - start_seconds))

[ "$elapsed_seconds" -le 4 ] ||
  fail "bounded tachyon-core probes took ${elapsed_seconds}s"
[ "$(wc -l <"$PROBE_COUNT")" -eq 1 ] ||
  fail "parallel UI requests must share one tachyon-core probe"

for output in "$WORK_DIR"/slow-*.json; do
  JSON_FILE="$output" node - <<'NODE'
const fs = require('fs');
const value = JSON.parse(fs.readFileSync(process.env.JSON_FILE, 'utf8'));
if (typeof value !== 'object' || value === null || typeof value.tachyon_core_tailscale !== 'number') {
  console.error('failed tachyon-core probe must still return valid capabilities JSON:', value);
  process.exit(1);
}
NODE
done

CACHE_FILE="$CACHE_FILE" node - <<'NODE'
const fs = require('fs');
const cache = JSON.parse(fs.readFileSync(process.env.CACHE_FILE, 'utf8'));
if (cache.success !== false) {
  console.error('timed-out probe must record negative cache entry:', cache);
  process.exit(1);
}
NODE

TACHYON_TEST_CORE_PROBE_MODE=slow ui_capabilities >/dev/null
[ "$(wc -l <"$PROBE_COUNT")" -eq 1 ] ||
  fail "failed tachyon-core probe must be cached during the retry cooldown"

while IFS= read -r pid; do
  if kill -0 "$pid" 2>/dev/null; then
    fail "timed-out tachyon-core probe process $pid is still running"
  fi
done <"$PROBE_PIDS"
: >"$PROBE_PIDS"

printf 'UI tachyon-core probe checks passed\n'
