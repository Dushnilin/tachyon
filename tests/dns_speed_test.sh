#!/usr/bin/env bash
set -eo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/state"
cat > "$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
exec ucode "$DNS_SPEED_CURL_FIXTURE" "$@"
SH
chmod +x "$WORK_DIR/bin/curl"
export PATH="$WORK_DIR/bin:$PATH" TACHYON_LIB
export TACHYON_UI_STATE_DIR="$WORK_DIR/state"
export DNS_SPEED_CURL_FIXTURE="$ROOT_DIR/tests/dns_speed_test_curl.uc"
export DNS_SPEED_FIXTURE_TRACE="$WORK_DIR/curl-args.json"
ucode -S -L "$TACHYON_LIB" -c -o /dev/null "$TACHYON_LIB/dns/speed_test.uc"
ucode -L "$TACHYON_LIB" "$ROOT_DIR/tests/dns_speed_test.uc"
