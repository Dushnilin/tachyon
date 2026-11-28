#!/usr/bin/env bash
# Regression test for subscription_engine='core' with auto_user_agent='0':
# When a subscription explicitly configures a custom User-Agent (or 'tachyon-core'),
# try_fetch_subscription_with_core() must store the configured User-Agent instead
# of overwriting .user_agent with tachyon-core's system banner, and
# finalize_downloaded_subscription_cache() must signal changed (exit 0) if a
# previously mismatched .user_agent file is repaired.

. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

CACHE_UC="$TACHYON_LIB/subscription/cache.uc"

TMP_CORE_DIR="$WORK_DIR/tmp-core"
TMP_SUB_DIR="$TMP_CORE_DIR/subscriptions"
PERSIST_SUB_DIR="$WORK_DIR/persist-sub"
STATE_DIR="$WORK_DIR/run-state"
mkdir -p "$TMP_CORE_DIR/rulesets" "$TMP_SUB_DIR" "$PERSIST_SUB_DIR" \
  "$STATE_DIR/subscription-update" "$STATE_DIR/subscription-links" \
  "$STATE_DIR/subscription-metadata" "$STATE_DIR/outbound-metadata" \
  "$STATE_DIR/section-cache"

FAKE_BIN="$WORK_DIR/bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/logger" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKE_BIN/logger"

CORE_UA_LOG="$WORK_DIR/core_fetch_ua.log"
MOCK_CORE="$WORK_DIR/mock-tachyon-core"
cat >"$MOCK_CORE" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "subscription" ] && [ "$2" = "hwid" ]; then
  printf 'test-hwid-123\n'
  exit 0
fi
if [ "$1" = "subscription" ] && [ "$2" = "fetch" ]; then
  shift 2
  out_file=""
  req_ua=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -o) out_file="$2"; shift 2 ;;
      --ua) req_ua="$2"; shift 2 ;;
      --hwid) shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -n "${TEST_CORE_UA_LOG:-}" ]; then
    printf '%s\n' "$req_ua" >> "$TEST_CORE_UA_LOG"
  fi
  cat >"$out_file" <<'JSON'
{
  "user_agent": "tachyon-core/0.6.9 (compatible; sing-box 1.14.3)",
  "metadata": {
    "profile_title": "Test Sub"
  },
  "outbounds": [
    {
      "type": "vless",
      "tag": "sub-node-1",
      "server": "vless.example.com",
      "server_port": 443,
      "uuid": "11111111-1111-4111-8111-111111111111"
    }
  ],
  "raw_body": ""
}
JSON
  exit 0
fi
exit 1
SH
chmod +x "$MOCK_CORE"

UCI_STATE_FILE="$WORK_DIR/uci.state"
SUB_URL="https://sub.example.com/custom"

write_uci_state() {
  local ua_val="$1"
  cat >"$UCI_STATE_FILE" <<EOF
tachyon.settings=settings
tachyon.settings.subscription_engine=core
tachyon.src_custom=outbound_source
tachyon.src_custom.enabled=1
tachyon.src_custom.name=CustomUA
tachyon.src_custom.source_type=subscription
tachyon.src_custom.url=$SUB_URL
tachyon.src_custom.subscription_engine=auto
tachyon.src_custom.auto_user_agent=0
tachyon.src_custom.user_agent=$ua_val
tachyon.sub_sec=section
tachyon.sub_sec.enabled=1
tachyon.sub_sec.action=proxy
tachyon.sub_sec.outbound_source_refs=src_custom
tachyon.sub_sec.subscription_urls=$SUB_URL
tachyon.sub_sec.subscription_engine=auto
tachyon.sub_sec.auto_user_agent=0
tachyon.sub_sec.user_agent=$ua_val
EOF
}

run_update_source() {
  set +e
  UCI_STATE="$UCI_STATE_FILE" \
  TACHYON_LIB="$TACHYON_LIB" \
  TACHYON_CORE_BIN="$MOCK_CORE" \
  TMP_TACHYON_CORE_FOLDER="$TMP_CORE_DIR" \
  TMP_SUBSCRIPTION_FOLDER="$TMP_SUB_DIR" \
  TACHYON_RUNTIME_STATE_DIR="$STATE_DIR" \
  TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$PERSIST_SUB_DIR" \
  TEST_CORE_UA_LOG="$CORE_UA_LOG" \
  PATH="$FAKE_BIN:$PATH" \
    ucode -L "$TACHYON_LIB" "$CACHE_UC" update-source sub_sec 1 "$SUB_URL" runtime "$WORK_DIR/meta.json"
  local rc=$?
  set -e
  return $rc
}

check_source_current() {
  local expected_ua="$1"
  UCI_STATE="$UCI_STATE_FILE" \
  TACHYON_LIB="$TACHYON_LIB" \
  TMP_SUBSCRIPTION_FOLDER="$TMP_SUB_DIR" \
  TACHYON_RUNTIME_STATE_DIR="$STATE_DIR" \
    ucode -L "$TACHYON_LIB" -e '
      let sub = require("tachyon_core.subscription");
      let sid = sub.source_id("sub_sec", 1);
      if (!sub.source_cache_is_current(sid, "'"$SUB_URL"'", "'"$expected_ua"'", "", "")) {
          warn("source_cache_is_current returned false for sid=" + sid + " ua=" + "'"$expected_ua"'" + "\n");
          exit(1);
      }
      let obs = sub.read_source_outbounds(sid);
      if (length(obs) == 0) {
          warn("read_source_outbounds empty for sid=" + sid + "\n");
          exit(1);
      }
    '
}

SID="$(ucode -L "$TACHYON_LIB" -e 'print(require("tachyon_core.subscription").source_id("sub_sec", 1));')"
UA_FILE="$TMP_SUB_DIR/$SID.user_agent"

# 1. Explicit custom User-Agent ('v2rayNG') must be persisted even though core returned banner UA
write_uci_state "v2rayNG"
: >"$CORE_UA_LOG"
rc=0
run_update_source || rc=$?
[ "$rc" = "0" ] || fail "scenario 1: expected update-source rc=0 on initial import, got $rc"
[ -f "$UA_FILE" ] || fail "scenario 1: missing $UA_FILE"
actual_ua="$(cat "$UA_FILE")"
[ "$actual_ua" = "v2rayNG" ] ||
  fail "scenario 1: expected cached .user_agent 'v2rayNG', got '$actual_ua'"
grep -Fxq 'v2rayNG' "$CORE_UA_LOG" ||
  fail "scenario 1: mock core did not receive --ua v2rayNG"
check_source_current "v2rayNG" || fail "scenario 1: source_cache_is_current failed for v2rayNG"

# 2. If a stale mismatched .user_agent exists (in both runtime and persistent cache)
#    from an unpatched run while .json outbounds match, update-source must repair
#    .user_agent and return 0 (changed) rather than 2 (unchanged).
printf '%s' 'tachyon-core/0.6.9 (compatible; sing-box 1.14.3)' >"$UA_FILE"
printf '%s' 'tachyon-core/0.6.9 (compatible; sing-box 1.14.3)' >"$PERSIST_SUB_DIR/$SID.user_agent"
rc=0
run_update_source || rc=$?
[ "$rc" = "0" ] ||
  fail "scenario 2: repairing stale .user_agent must return rc=0 (changed), got $rc"
actual_ua="$(cat "$UA_FILE")"
[ "$actual_ua" = "v2rayNG" ] ||
  fail "scenario 2: expected repaired .user_agent 'v2rayNG', got '$actual_ua'"
[ "$(cat "$PERSIST_SUB_DIR/$SID.user_agent")" = "v2rayNG" ] ||
  fail "scenario 2: expected repaired persistent .user_agent 'v2rayNG'"
check_source_current "v2rayNG" || fail "scenario 2: source_cache_is_current failed after repair"

# 3. Steady unchanged update returns 2 (unchanged)
rc=0
run_update_source || rc=$?
[ "$rc" = "2" ] || fail "scenario 3: steady re-fetch expected rc=2 (unchanged), got $rc"

# 4. Explicit 'tachyon-core' User-Agent also preserved cleanly
write_uci_state "tachyon-core"
rc=0
run_update_source || rc=$?
[ "$rc" = "0" ] || fail "scenario 4: expected rc=0 when switching UA to tachyon-core, got $rc"
actual_ua="$(cat "$UA_FILE")"
[ "$actual_ua" = "tachyon-core" ] ||
  fail "scenario 4: expected cached .user_agent 'tachyon-core', got '$actual_ua'"
check_source_current "tachyon-core" || fail "scenario 4: source_cache_is_current failed for tachyon-core"

printf 'core_sub_custom_user_agent: OK\n'
