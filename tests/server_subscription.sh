#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail
ucode -L "$TACHYON_LIB" "$ROOT_DIR/tests/server_subscription.uc"
grep -q 'files/www/cgi-bin/tachyon-sub' "$ROOT_DIR/tachyon/Makefile" || fail 'OpenWrt package omits subscription CGI'
grep -q 'files/www/cgi-bin/tachyon-sub' "$ROOT_DIR/build.sh" || fail 'release package omits subscription CGI'
sh -n "$ROOT_DIR/tachyon/files/www/cgi-bin/tachyon-sub"

TOKEN=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
cat >"$WORK_DIR/uci.state" <<EOF
tachyon.settings=settings
tachyon.settings.server_subscription_enabled=1
tachyon.settings.server_subscription_token=$TOKEN
tachyon.settings.server_subscription_host=vpn.example.com
tachyon.fixture=server
tachyon.fixture.protocol=vless
tachyon.fixture.security=none
tachyon.fixture.server_uuid=33333333-3333-4333-8333-333333333333
EOF
cgi_request() {
  env TACHYON_LIB="$TACHYON_LIB" TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state" TACHYON_BIN=/bin/false \
    REQUEST_METHOD="$1" PATH_INFO="$2" QUERY_STRING="$3" sh "$ROOT_DIR/tachyon/files/www/cgi-bin/tachyon-sub"
}
cgi_request GET "/$TOKEN" format=plain >"$WORK_DIR/response"
grep -q '^Status: 200 OK' "$WORK_DIR/response" || fail 'CGI must serve an authorized subscription'
grep -q '^Cache-Control: no-store' "$WORK_DIR/response" || fail 'credentials must never be cached'
grep -q '^vless://' "$WORK_DIR/response" || fail 'CGI must use saved UCI data'
cgi_request GET /wrong format=plain >"$WORK_DIR/denied"
grep -q '^Status: 404 Not Found' "$WORK_DIR/denied" || fail 'CGI must deny a wrong token'
! grep -q '33333333\|vless://' "$WORK_DIR/denied" || fail 'denied response leaked credentials'
cgi_request HEAD "/$TOKEN" format=plain >"$WORK_DIR/head"
! grep -q 'vless://' "$WORK_DIR/head" || fail 'HEAD must omit subscription body'
