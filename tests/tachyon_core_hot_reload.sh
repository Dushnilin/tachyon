#!/usr/bin/env bash
# Verifies tachyon-core hot reload integration:
# 1. SIGHUP hot reload is gated exclusively on tachyon-core (disabled for sing-box variants).
# 2. save_config_file runs `tachyon-core reload-preview` and writes reload-preview.json.
# 3. try_sighup_reload aborts when reload-preview reports `in_place: false`.
# 4. try_sighup_reload verifies GET /tachyon/config-state and triggers POST /tachyon/route-recheck.
# 5. managed_core_init_script includes reload_service() so `/etc/init.d/tachyon-core reload` uses SIGHUP.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

STATE_UC="$TACHYON_LIB/service/state.uc"
RUNTIME_UC="$TACHYON_LIB/tachyon_core/runtime.uc"
PROC_UC="$TACHYON_LIB/core/process.uc"
UCODE_BIN="$(command -v ucode)"

[ -f "$STATE_UC" ] || fail "service/state.uc not found"
[ -f "$RUNTIME_UC" ] || fail "tachyon_core/runtime.uc not found"
[ -f "$PROC_UC" ] || fail "core/process.uc not found"

cleanup_extra() {
  [ -n "${FAKE_PID:-}" ] && kill "$FAKE_PID" 2>/dev/null || true
  [ -n "${SINGBOX_PID:-}" ] && kill "$SINGBOX_PID" 2>/dev/null || true
  [ -n "${HTTP_PID:-}" ] && kill "$HTTP_PID" 2>/dev/null || true
  release_core_proc_lock
  return 0
}
trap 'cleanup_extra; cleanup' EXIT

acquire_core_proc_lock

# --- 1. managed_core_init_script defines reload_service() --------------------
init_script="$("$UCODE_BIN" -L "$TACHYON_LIB" "$PROC_UC" init-script marker)"
printf '%s\n' "$init_script" | grep -Fq 'reload_service()' ||
  fail "managed_core_init_script must define reload_service()"
printf '%s\n' "$init_script" | grep -Fq 'sighup-core-runtime' ||
  fail "reload_service() must invoke service/state.uc sighup-core-runtime"

# --- 2. save_config_file writes reload-preview.json for tachyon-core ---------
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run"
PREVIEW_FILE="$WORK_DIR/run/reload-preview.json"
VARIANT_FILE="$WORK_DIR/tachyon-core-variant"
printf 'tachyon-core\n' >"$VARIANT_FILE"

cat >"$WORK_DIR/bin/tachyon-core" <<'EOF_CORE'
#!/bin/sh
if [ "$1" = "version" ]; then
  printf 'tachyon-core 0.0.1\n'
  exit 0
fi
if [ "$1" = "reload-preview" ]; then
  printf '{"in_place":true,"current_digest":"aaa111","candidate_digest":"bbb222"}\n'
  exit 0
fi
exec /bin/sleep "$@"
EOF_CORE
sed -i 's/\r$//' "$WORK_DIR/bin/tachyon-core"
chmod +x "$WORK_DIR/bin/tachyon-core"

printf '{"version":1}\n' >"$WORK_DIR/current.json"
printf '{"version":2}\n' >"$WORK_DIR/candidate.json"

PATH="$WORK_DIR/bin:$PATH" \
  SB_VARIANT_STATE_FILE="$VARIANT_FILE" \
  TACHYON_RELOAD_PREVIEW_FILE="$PREVIEW_FILE" \
  "$UCODE_BIN" -L "$TACHYON_LIB" "$RUNTIME_UC" save-config-file-fixture \
  "$WORK_DIR/candidate.json" "$WORK_DIR/current.json" ||
  fail "save-config-file-fixture failed"

[ -f "$PREVIEW_FILE" ] || fail "save_config_file must write reload-preview.json when tachyon-core is active"
grep -Fq '"candidate_digest": "bbb222"' "$PREVIEW_FILE" ||
  fail "reload-preview.json must record candidate_digest"
grep -Fq '"subsystems":' "$PREVIEW_FILE" ||
  fail "reload-preview.json must record subsystems summary"
grep -Fq '"changed_subsystems":' "$PREVIEW_FILE" ||
  fail "reload-preview.json must record changed_subsystems list"

# When sing-box (e.g. lx) is active, save_config_file must NOT leave a reload-preview.json
printf 'lx\n' >"$VARIANT_FILE"
printf '{"version":3}\n' >"$WORK_DIR/candidate2.json"
PATH="$WORK_DIR/bin:$PATH" \
  SB_VARIANT_STATE_FILE="$VARIANT_FILE" \
  TACHYON_RELOAD_PREVIEW_FILE="$PREVIEW_FILE" \
  "$UCODE_BIN" -L "$TACHYON_LIB" "$RUNTIME_UC" save-config-file-fixture \
  "$WORK_DIR/candidate2.json" "$WORK_DIR/current.json" ||
  fail "save-config-file-fixture failed for lx"
[ ! -f "$PREVIEW_FILE" ] || fail "save_config_file must remove reload-preview.json when sing-box variant is active"

# --- 3. SIGHUP gating: only tachyon-core is allowed --------------------------
cp /bin/sleep "$WORK_DIR/bin/tachyon-core"
cp /bin/sleep "$WORK_DIR/bin/sing-box"

( trap '' HUP; exec "$WORK_DIR/bin/tachyon-core" 120 ) &
FAKE_PID=$!
( trap '' HUP; exec "$WORK_DIR/bin/sing-box" 120 ) &
SINGBOX_PID=$!
sleep 0.5

cat >"$WORK_DIR/config.json" <<'JSON'
{
  "inbounds": [],
  "outbounds": []
}
JSON
printf 'tachyon.settings.config_path=%s\n' "$WORK_DIR/config.json" >"$WORK_DIR/uci.state"

# 3a. sing-box executable must be rejected by try_sighup_reload
rm -f "$VARIANT_FILE"
if TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state" \
  SB_VARIANT_STATE_FILE="$VARIANT_FILE" \
  TACHYON_RELOAD_PREVIEW_FILE="$PREVIEW_FILE" \
  "$UCODE_BIN" -L "$TACHYON_LIB" "$STATE_UC" sighup-core-runtime "$SINGBOX_PID" >/dev/null 2>&1; then
  fail "try_sighup_reload must reject sing-box process"
fi

# 3b. sing-box variant marker (lx/extended/stable) must reject SIGHUP even on tachyon-core binary path
for marker in lx extended extended-compressed tiny stable; do
  printf '%s\n' "$marker" >"$VARIANT_FILE"
  if TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state" \
    SB_VARIANT_STATE_FILE="$VARIANT_FILE" \
    TACHYON_RELOAD_PREVIEW_FILE="$PREVIEW_FILE" \
    "$UCODE_BIN" -L "$TACHYON_LIB" "$STATE_UC" sighup-core-runtime "$FAKE_PID" >/dev/null 2>&1; then
    fail "try_sighup_reload must reject SIGHUP when marker is $marker"
  fi
done

# 3c. tachyon-core marker succeeds
printf 'tachyon-core\n' >"$VARIANT_FILE"
TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state" \
  SB_VARIANT_STATE_FILE="$VARIANT_FILE" \
  TACHYON_RELOAD_PREVIEW_FILE="$PREVIEW_FILE" \
  "$UCODE_BIN" -L "$TACHYON_LIB" "$STATE_UC" sighup-core-runtime "$FAKE_PID" >/dev/null 2>&1 ||
  fail "try_sighup_reload must succeed for tachyon-core"

# --- 4. reload-preview in_place: false aborts SIGHUP -------------------------
printf '{"in_place":false,"current_digest":"aaa","candidate_digest":"bbb"}\n' >"$PREVIEW_FILE"
if TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state" \
  SB_VARIANT_STATE_FILE="$VARIANT_FILE" \
  TACHYON_RELOAD_PREVIEW_FILE="$PREVIEW_FILE" \
  "$UCODE_BIN" -L "$TACHYON_LIB" "$STATE_UC" sighup-core-runtime "$FAKE_PID" >/dev/null 2>&1; then
  fail "try_sighup_reload must return false when reload-preview reports in_place: false"
fi
[ -f "$PREVIEW_FILE" ] || fail "try_sighup_reload must preserve reload-preview.json on disk for inspection"

# --- 5. /tachyon/config-state verification & /tachyon/route-recheck ----------
API_PORT=45991
STATE_RESP_FILE="$WORK_DIR/config_state_resp.json"
STATE_CALL_COUNTER="$WORK_DIR/config_state_calls"
RECHECK_LOG="$WORK_DIR/recheck_called.log"
printf '0\n' >"$STATE_CALL_COUNTER"
: >"$RECHECK_LOG"

cat >"$WORK_DIR/bin/curl" <<EOF_CURL
#!/bin/sh
method="GET"
url=""
for arg in "\$@"; do
  if [ "\$prev" = "-X" ]; then
    method="\$arg"
  fi
  prev="\$arg"
  url="\$arg"
done
case "\$url" in
  */tachyon/config-state)
    count=\$(cat "$STATE_CALL_COUNTER" 2>/dev/null || echo 0)
    count=\$((count + 1))
    printf '%s\n' "\$count" >"$STATE_CALL_COUNTER"
    if [ "\$count" -eq 1 ]; then
      cat "$WORK_DIR/state_before.json"
    else
      cat "$STATE_RESP_FILE"
    fi
    exit 0
    ;;
  */tachyon/route-recheck)
    printf '%s /tachyon/route-recheck\n' "\$method" >>"$RECHECK_LOG"
    printf '{"evaluated":5,"closed":1,"stale":false}\n'
    exit 0
    ;;
esac
exit 1
EOF_CURL
sed -i 's/\r$//' "$WORK_DIR/bin/curl"
chmod +x "$WORK_DIR/bin/curl"

cat >"$WORK_DIR/config.json" <<JSON
{
  "inbounds": [],
  "outbounds": [],
  "experimental": {
    "clash_api": {
      "external_controller": "127.0.0.1:$API_PORT",
      "secret": "test-secret"
    }
  }
}
JSON

printf '{"pid":%s,"revision":1,"digest":"aaa111","ready":true}\n' "$FAKE_PID" >"$WORK_DIR/state_before.json"
printf '{"pid":%s,"revision":2,"digest":"bbb222","ready":true}\n' "$FAKE_PID" >"$STATE_RESP_FILE"
printf '{"in_place":true,"current_digest":"aaa111","candidate_digest":"bbb222"}\n' >"$PREVIEW_FILE"

PATH="$WORK_DIR/bin:$PATH" \
  TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state" \
  SB_VARIANT_STATE_FILE="$VARIANT_FILE" \
  TACHYON_RELOAD_PREVIEW_FILE="$PREVIEW_FILE" \
  "$UCODE_BIN" -L "$TACHYON_LIB" "$STATE_UC" sighup-core-runtime "$FAKE_PID" >/dev/null 2>&1 ||
  fail "try_sighup_reload must succeed when /tachyon/config-state matches candidate_digest"

grep -Fq 'POST /tachyon/route-recheck' "$RECHECK_LOG" ||
  fail "try_sighup_reload must call POST /tachyon/route-recheck after confirming hot reload"

printf 'PASS: tachyon_core_hot_reload\n'
