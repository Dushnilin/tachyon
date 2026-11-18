#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

RUNTIME_UC="$TACHYON_LIB/diagnostics/runtime.uc"
BIN_DIR="$WORK_DIR/bin"
DAEMON_DIR="$WORK_DIR/daemon"
UCI_STATE="$WORK_DIR/uci.state"
CORE_CFG="$WORK_DIR/core-config.json"
CURL_LOG="$WORK_DIR/curl.log"
DAEMON_PID=""

cleanup() {
  if [ -n "${DAEMON_PID:-}" ]; then
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  release_core_proc_lock
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

acquire_core_proc_lock

if pidof tachyon-core >/dev/null 2>&1; then
  fail "test needs no tachyon-core process running"
fi

mkdir -p "$BIN_DIR" "$DAEMON_DIR"

# Stub tachyon-core matching the real Rust binary: supports `-c ... check`,
# rejects removed `tools fetch` subcommand.
cat >"$BIN_DIR/tachyon-core" <<'SH'
#!/bin/sh
if [ "${1:-}" = "tools" ] && [ "${2:-}" = "fetch" ]; then
  echo "unknown command: tools" >&2
  exit 1
fi
if [ "${1:-}" = "-c" ] && [ "${3:-}" = "check" ] && [ -f "${2:-}" ]; then
  exit 0
fi
echo "unexpected tachyon-core args: $*" >&2
exit 2
SH
chmod +x "$BIN_DIR/tachyon-core"

# ELF binary stand-in for background tachyon-core daemon detection.
SLEEP_BIN="$(command -v sleep)"
cp "$SLEEP_BIN" "$DAEMON_DIR/tachyon-core"
chmod +x "$DAEMON_DIR/tachyon-core"

# Stub curl that validates --proxy http://127.0.0.1:... and logs invocations.
cat >"$BIN_DIR/curl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$CURL_LOG"
proxy_url=""
target_url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --proxy|-x)
      proxy_url="$2"
      shift 2
      ;;
    --connect-timeout|--max-time)
      shift 2
      ;;
    http://*|https://*)
      target_url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

case "$proxy_url" in
  http://127.0.0.1:*) ;;
  *)
    echo "curl stub expected --proxy http://127.0.0.1:..., got '$proxy_url'" >&2
    exit 99
    ;;
esac

case "${CURL_TEST_MODE:-ok}" in
  ok)
    printf '%s\n' "${CURL_TEST_IP:-203.0.113.42}"
    exit 0
    ;;
  ipv6)
    printf '2001:db8:85a3::8a2e:370:7334\n'
    exit 0
    ;;
  fallback)
    case "$target_url" in
      *ifconfig.me*)
        echo "curl: (22) The requested URL returned error: 503" >&2
        exit 22
        ;;
      *)
        printf '198.51.100.7\n'
        exit 0
        ;;
    esac
    ;;
  fail)
    echo "curl: (7) Failed to connect to 127.0.0.1 port 4534: Connection refused" >&2
    exit 7
    ;;
  *)
    echo "unknown CURL_TEST_MODE: ${CURL_TEST_MODE}" >&2
    exit 98
    ;;
esac
SH
chmod +x "$BIN_DIR/curl"

cat >"$UCI_STATE" <<EOF
tachyon.settings=settings
tachyon.settings.config_path=$CORE_CFG
EOF

write_core_config() {
  local inbounds_json="$1"
  cat >"$CORE_CFG" <<JSON
{
  "inbounds": $inbounds_json,
  "outbounds": [
    {
      "type": "vless",
      "tag": "proxy-out",
      "server": "vpn.example.com",
      "server_port": 443,
      "uuid": "secret-uuid-1234"
    }
  ]
}
JSON
}

run_check_proxy() {
  local mode="$1"
  : >"$CURL_LOG"
  set +e
  CHECK_OUTPUT="$(
    PATH="$BIN_DIR:$PATH" \
    TACHYON_UCI_STATE_FILE="$UCI_STATE" \
    TACHYON_CORE_CONFIG="$CORE_CFG" \
    CURL_LOG="$CURL_LOG" \
    CURL_TEST_MODE="$mode" \
    ucode -L "$TACHYON_LIB" "$RUNTIME_UC" check-proxy 2>&1
  )"
  CHECK_RC=$?
  set -e
}

# 1. Not running: clear diagnostic message instead of Empty response.
write_core_config '[{"type":"mixed","tag":"service-mixed-in","listen":"127.0.0.1","listen_port":4534}]'
run_check_proxy ok
[ "$CHECK_RC" -ne 0 ] || fail "check_proxy must fail when tachyon-core is not running"
printf '%s\n' "$CHECK_OUTPUT" | grep -Fq "tachyon-core is not running" ||
  fail "expected clear not-running message, got: $CHECK_OUTPUT"
if printf '%s\n' "$CHECK_OUTPUT" | grep -Fq "Empty response"; then
  fail "must not report Empty response when tachyon-core is not running: $CHECK_OUTPUT"
fi

# Start dummy tachyon-core daemon for live checks.
"$DAEMON_DIR/tachyon-core" 120 &
DAEMON_PID=$!
sleep 0.2
pidof tachyon-core >/dev/null 2>&1 || fail "dummy tachyon-core daemon did not start"

# 2. Missing local mixed inbound: clear diagnostic message instead of Empty response.
write_core_config '[{"type":"tproxy","tag":"tproxy-in","listen":"0.0.0.0","listen_port":1602}]'
run_check_proxy ok
[ "$CHECK_RC" -ne 0 ] || fail "check_proxy must fail when no local mixed inbound is configured"
printf '%s\n' "$CHECK_OUTPUT" | grep -Fq "No local mixed inbound" ||
  fail "expected clear missing-inbound message, got: $CHECK_OUTPUT"
if printf '%s\n' "$CHECK_OUTPUT" | grep -Fq "Empty response"; then
  fail "must not report Empty response when no local mixed inbound exists: $CHECK_OUTPUT"
fi

# 3. Success via service-mixed-in (skipping direct-bypass-in), masked config + masked IP.
write_core_config '[
  {"type":"mixed","tag":"direct-bypass-in","listen":"0.0.0.0","listen_port":2080},
  {"type":"mixed","tag":"service-mixed-in","listen":"127.0.0.1","listen_port":4534}
]'
run_check_proxy ok
[ "$CHECK_RC" -eq 0 ] || fail "check_proxy expected exit 0 on success, got $CHECK_RC: $CHECK_OUTPUT"
printf '%s\n' "$CHECK_OUTPUT" | grep -Fq "X.X.X.42 - should match proxy IP" ||
  fail "expected masked IPv4 line, got: $CHECK_OUTPUT"
printf '%s\n' "$CHECK_OUTPUT" | grep -Fq '"MASKED"' ||
  fail "expected masked core config output, got: $CHECK_OUTPUT"
if printf '%s\n' "$CHECK_OUTPUT" | grep -Fq "secret-uuid-1234"; then
  fail "core config output leaked unmasked secret: $CHECK_OUTPUT"
fi
grep -Fq -- "--proxy http://127.0.0.1:4534" "$CURL_LOG" ||
  fail "curl was not invoked with --proxy http://127.0.0.1:4534: $(cat "$CURL_LOG")"

# 4. Wildcard listen normalization (0.0.0.0 and :: -> 127.0.0.1:<port>) on mixed-in.
write_core_config '[{"type":"mixed","tag":"mixed-in","listen":"0.0.0.0","listen_port":14534}]'
run_check_proxy ok
[ "$CHECK_RC" -eq 0 ] || fail "check_proxy failed on 0.0.0.0 mixed-in: $CHECK_OUTPUT"
grep -Fq -- "--proxy http://127.0.0.1:14534" "$CURL_LOG" ||
  fail "expected 0.0.0.0 to connect via 127.0.0.1:14534: $(cat "$CURL_LOG")"

write_core_config '[{"type":"mixed","tag":"mixed-in","listen":"::","listen_port":24534}]'
run_check_proxy ok
[ "$CHECK_RC" -eq 0 ] || fail "check_proxy failed on :: mixed-in: $CHECK_OUTPUT"
grep -Fq -- "--proxy http://127.0.0.1:24534" "$CURL_LOG" ||
  fail "expected :: to connect via 127.0.0.1:24534: $(cat "$CURL_LOG")"

# 5. Fallback URL probe & IPv6 masking.
write_core_config '[{"type":"mixed","tag":"service-mixed-in","listen":"127.0.0.1","listen_port":4534}]'
run_check_proxy fallback
[ "$CHECK_RC" -eq 0 ] || fail "check_proxy must succeed via fallback probe URL: $CHECK_OUTPUT"
printf '%s\n' "$CHECK_OUTPUT" | grep -Fq "X.X.X.7 - should match proxy IP" ||
  fail "expected fallback masked IPv4 line, got: $CHECK_OUTPUT"

run_check_proxy ipv6
[ "$CHECK_RC" -eq 0 ] || fail "check_proxy must succeed on IPv6 response: $CHECK_OUTPUT"
printf '%s\n' "$CHECK_OUTPUT" | grep -Fq "2001:db8:85a3:XXXX:XXXX:XXXX - should match proxy IP" ||
  fail "expected masked IPv6 line, got: $CHECK_OUTPUT"

# 6. Failure captures real curl error instead of Empty response and exits 1.
run_check_proxy fail
[ "$CHECK_RC" -eq 1 ] || fail "check_proxy expected exit 1 on failure, got $CHECK_RC: $CHECK_OUTPUT"
printf '%s\n' "$CHECK_OUTPUT" | grep -Fq "Failed to get valid IP address after 3 attempts" ||
  fail "expected failure attempt summary, got: $CHECK_OUTPUT"
printf '%s\n' "$CHECK_OUTPUT" | grep -Fq "Error: curl: (7) Failed to connect to 127.0.0.1 port 4534: Connection refused" ||
  fail "expected captured curl error, got: $CHECK_OUTPUT"
if printf '%s\n' "$CHECK_OUTPUT" | grep -Fq "Empty response"; then
  fail "failure must report curl error instead of Empty response: $CHECK_OUTPUT"
fi

# 7. Full CLI entrypoint (`tachyon check_proxy`) works end-to-end too.
TACHYON_CLI="$ROOT_DIR/tachyon/files/usr/bin/tachyon"
CLI_OUT="$(
  PATH="$BIN_DIR:$PATH" \
  TACHYON_UCI_STATE_FILE="$UCI_STATE" \
  TACHYON_CORE_CONFIG="$CORE_CFG" \
  CURL_LOG="$CURL_LOG" \
  CURL_TEST_MODE="ok" \
  ucode "$TACHYON_CLI" check_proxy 2>&1
)" || fail "tachyon check_proxy CLI invocation failed: $CLI_OUT"
printf '%s\n' "$CLI_OUT" | grep -Fq "X.X.X.42 - should match proxy IP" ||
  fail "tachyon check_proxy CLI output missing masked IP: $CLI_OUT"

printf 'check_proxy tachyon-core checks passed\n'
