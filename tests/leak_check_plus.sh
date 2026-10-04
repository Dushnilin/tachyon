#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail
mkdir -p "$WORK_DIR/bin"
cat > "$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
exec ucode -- "$DNS_TRANSPORT_CURL_FIXTURE" "$@"
SH
chmod +x "$WORK_DIR/bin/curl"
export PATH="$WORK_DIR/bin:$PATH" TACHYON_LIB
export DNS_TRANSPORT_CURL_FIXTURE="$ROOT_DIR/tests/dns_transport_curl.uc"
export DNS_TRANSPORT_TRACE="$WORK_DIR/trace.json"
export DNS_TRANSPORT_TEST_DIR="$WORK_DIR"
ucode -S -L "$TACHYON_LIB" -c -o /dev/null "$TACHYON_LIB/diagnostics/dns_transport.uc"
ucode -L "$TACHYON_LIB" "$ROOT_DIR/tests/leak_check_plus.uc"
