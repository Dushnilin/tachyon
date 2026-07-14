#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_RUNTIME="$ROOT_DIR/tachyon/files/usr/lib/server/service.uc"
UCODE_LIB="$ROOT_DIR/tachyon/files/usr/lib"
WORK_DIR="$(mktemp -d)"
STATE="$WORK_DIR/uci.state"
LOG="$WORK_DIR/uci.log"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'UCI state:\n' >&2
  cat "$STATE" >&2 2>/dev/null || true
  printf 'UCI log:\n' >&2
  cat "$LOG" >&2 2>/dev/null || true
  exit 1
}

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/sing-box" <<'SINGBOX'
#!/usr/bin/env bash
set -eo pipefail

case "$*" in
  "generate uuid")
    printf '%s\n' '33333333-3333-4333-8333-333333333333'
    ;;
  "generate rand --base64 18")
    printf '%s\n' 'generated-password'
    ;;
  "generate rand --hex 4")
    printf '%s\n' 'abcd1234'
    ;;
  "generate rand --hex 16")
    printf '%s\n' '11111111111111111111111111111111'
    ;;
  "generate reality-keypair")
    printf 'PrivateKey: private-key\nPublicKey: public-key\n'
    ;;
  *)
    printf 'unsupported sing-box command: %s\n' "$*" >&2
    exit 2
    ;;
esac
SINGBOX
chmod 0755 "$WORK_DIR/bin/sing-box"

cat >"$WORK_DIR/bin/logger" <<'LOGGER'
#!/usr/bin/env bash
set -eo pipefail
exit 0
LOGGER
chmod 0755 "$WORK_DIR/bin/logger"

export PATH="$WORK_DIR/bin:$PATH"
export TACHYON_UCI_STATE_FILE="$STATE"
export TACHYON_UCI_LOG_FILE="$LOG"
export TACHYON_CONFIG_NAME="tachyon"
export TACHYON_SERVER_RUNTIME_UC="$SERVER_RUNTIME"

if grep -E 'uci -q|command -v uci' "$SERVER_RUNTIME" >/dev/null; then
  fail "server/service.uc must use ucode UCI access instead of shelling out to uci"
fi
if grep -F 'output("ucode "' "$SERVER_RUNTIME" >/dev/null; then
  fail "server defaults must not spawn service.uc without the Tachyon module path"
fi

cat >"$STATE" <<'EOF_STATE'
tachyon.vless=server
tachyon.vless.protocol=vless
tachyon.vless.server_users=client|22222222-2222-4222-8222-222222222222|xtls-rprx-vision
tachyon.socks=server
tachyon.socks.protocol=socks
tachyon.socks.label=desk
tachyon.socks_open=server
tachyon.socks_open.protocol=socks
tachyon.socks_open.label=guest
tachyon.socks_open.socks_auth_enabled=0
tachyon.tailscale=server
tachyon.tailscale.protocol=tailscale
tachyon.json=server
tachyon.json.protocol=json_inbound
tachyon.mtproto=server
tachyon.mtproto.protocol=mtproto
tachyon.mtproto.mtproto_secret=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
tachyon.mtproto_legacy=server
tachyon.mtproto_legacy.protocol=mtproto
tachyon.mtproto_legacy.server_users=client|eebbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb676f6f676c652e636f6d
EOF_STATE

ucode -L "$UCODE_LIB" "$SERVER_RUNTIME" prepare-all-defaults

uci_get() {
  awk -F= -v key="$1" '$1 == key { print substr($0, length($1) + 2); found = 1 } END { exit found ? 0 : 1 }' "$STATE"
}

assert_value() {
  local path="$1" expected="$2" actual
  actual="$(uci_get "$path" 2>/dev/null || true)"
  [ "$actual" = "$expected" ] || fail "$path: expected '$expected', got '$actual'"
}

assert_value tachyon.vless.security reality
assert_value tachyon.vless.listen 0.0.0.0
assert_value tachyon.vless.listen_port 443
assert_value tachyon.vless.server_uuid 22222222-2222-4222-8222-222222222222
assert_value tachyon.vless.vless_flow xtls-rprx-vision
assert_value tachyon.vless.reality_short_id abcd1234
assert_value tachyon.vless.reality_private_key private-key
assert_value tachyon.vless.reality_public_key public-key
assert_value tachyon.socks.security none
assert_value tachyon.socks.socks_auth_enabled 1
assert_value tachyon.socks.server_username desk
assert_value tachyon.socks.server_password generated-password
assert_value tachyon.socks_open.socks_auth_enabled 0
assert_value tachyon.socks_open.server_username guest
assert_value tachyon.socks_open.server_password generated-password
assert_value tachyon.tailscale.security none
assert_value tachyon.tailscale.tailscale_control_url https://controlplane.tailscale.com
assert_value tachyon.tailscale.tailscale_hostname tachyon-tailscale
assert_value tachyon.tailscale.tailscale_advertise_exit_node 1
assert_value tachyon.json.security none
assert_value tachyon.mtproto.mtproto_secret aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
assert_value tachyon.mtproto_legacy.mtproto_secret bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
assert_value tachyon.mtproto_legacy.mtproto_faketls google.com
grep -Fxq 'commit tachyon' "$LOG" || fail 'expected config commit'

: >"$LOG"
ucode -L "$UCODE_LIB" "$SERVER_RUNTIME" prepare-all-defaults
[ ! -s "$LOG" ] || fail 'unchanged MTProto defaults must not rewrite or commit configuration on every reload'

printf 'server runtime checks passed\n'
