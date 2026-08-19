#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
RESET_UC="$TACHYON_LIB/service/reset.uc"
TACHYON_BIN="$ROOT_DIR/tachyon/files/usr/bin/tachyon"
REAL_LIB="$ROOT_DIR/tachyon/files/usr/lib"
INSTALLER="$ROOT_DIR/install.sh"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -r "$RESET_UC" ] || fail "service/reset.uc must own reset-to-defaults logic"
[ -r "$TACHYON_BIN" ] || fail "tachyon entrypoint is missing"

grep -Fq 'reset_settings: [ "service/reset.uc", "reset-settings", 1 ]' "$TACHYON_BIN" ||
  fail "tachyon entrypoint must dispatch reset_settings to service/reset.uc"
grep -Fq 'reset_settings' "$TACHYON_BIN" ||
  fail "tachyon entrypoint must list reset_settings in the command table"

mkdir -p "$WORK_DIR/lib/defaults"
cat >"$WORK_DIR/default-config" <<'EOF'
config settings 'settings'
        option config_version '1.0.5'
        option dns_type 'udp'
        option shutdown_correctly '0'
EOF
cp "$WORK_DIR/default-config" "$WORK_DIR/lib/defaults/config"

mkdir -p \
  "$WORK_DIR/persistent/subscription-cache" \
  "$WORK_DIR/persistent/rulesets" \
  "$WORK_DIR/persistent/tailscale/server-main"
printf '%s\n' 'stale-cache' >"$WORK_DIR/persistent/subscription-cache/cache.json"
printf '%s\n' 'stale-ruleset' >"$WORK_DIR/persistent/rulesets/community.srs"
printf '%s\n' 'tailscale-identity' >"$WORK_DIR/persistent/tailscale/server-main/node.key"
mkdir -p "$WORK_DIR/runtime" "$WORK_DIR/sing-box-tmp"
printf '%s\n' '{"log":{}}' >"$WORK_DIR/sing-box-tmp/config.json"
mkdir -p "$(dirname "$WORK_DIR/sing-box-config")"
printf '%s\n' '{"log":{}}' >"$WORK_DIR/sing-box-config"
printf '%s\n' 'custom-user-config' >"$WORK_DIR/config"

: >"$WORK_DIR/bin.log"
: >"$WORK_DIR/init.log"
cat >"$WORK_DIR/fake-bin" <<'SH'
#!/usr/bin/env sh
printf '%s\n' "$*" >> "$TACHYON_RESET_BIN_LOG"
exit 0
SH
chmod 0755 "$WORK_DIR/fake-bin"
cat >"$WORK_DIR/fake-init" <<'SH'
#!/usr/bin/env sh
printf '%s\n' "$*" >> "$TACHYON_RESET_INIT_LOG"
exit 0
SH
chmod 0755 "$WORK_DIR/fake-init"

TACHYON_LIB="$WORK_DIR/lib" \
TACHYON_BIN="$WORK_DIR/fake-bin" \
TACHYON_SERVICE_INIT="$WORK_DIR/fake-init" \
TACHYON_CONFIG_PATH="$WORK_DIR/config" \
TACHYON_PERSISTENT_DIR="$WORK_DIR/persistent" \
TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/runtime" \
TACHYON_SING_BOX_TMP_DIR="$WORK_DIR/sing-box-tmp" \
TACHYON_SING_BOX_CONFIG_PATH="$WORK_DIR/sing-box-config" \
TACHYON_RESET_BIN_LOG="$WORK_DIR/bin.log" \
TACHYON_RESET_INIT_LOG="$WORK_DIR/init.log" \
  ucode -L "$WORK_DIR/lib" -L "$REAL_LIB" "$RESET_UC" reset-settings no-start >"$WORK_DIR/result.json"
grep -Fq '"success":true' "$WORK_DIR/result.json" ||
  fail "reset-settings must report success"

grep -Fxq 'stop' "$WORK_DIR/bin.log" ||
  fail "reset must stop the service through the backend entrypoint"
grep -Fxq 'stop' "$WORK_DIR/init.log" ||
  fail "reset must stop the service through init.d"
if grep -Fxq 'start' "$WORK_DIR/init.log"; then
  fail "reset no-start must not start the service"
fi

cmp -s "$WORK_DIR/config" "$WORK_DIR/default-config" ||
  fail "reset must restore the config file to factory defaults"
[ "$(stat -c %a "$WORK_DIR/config")" = "600" ] ||
  fail "reset config must be chmod 600"

[ ! -e "$WORK_DIR/persistent/subscription-cache" ] ||
  fail "reset must remove stale subscription caches"
[ ! -e "$WORK_DIR/persistent/rulesets" ] ||
  fail "reset must remove stale ruleset caches"
[ "$(cat "$WORK_DIR/persistent/tailscale/server-main/node.key")" = 'tailscale-identity' ] ||
  fail "reset must preserve the Tailscale identity"
[ ! -e "$WORK_DIR/runtime" ] ||
  fail "reset must remove the runtime state directory"
[ ! -e "$WORK_DIR/sing-box-tmp" ] ||
  fail "reset must remove the sing-box temporary directory"
[ ! -e "$WORK_DIR/sing-box-config" ] ||
  fail "reset must remove the sing-box config file"

TACHYON_LIB="$WORK_DIR/lib" \
TACHYON_BIN="$WORK_DIR/fake-bin" \
TACHYON_SERVICE_INIT="$WORK_DIR/fake-init" \
TACHYON_CONFIG_PATH="$WORK_DIR/config" \
TACHYON_PERSISTENT_DIR="$WORK_DIR/persistent" \
TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/runtime" \
TACHYON_SING_BOX_TMP_DIR="$WORK_DIR/sing-box-tmp" \
TACHYON_SING_BOX_CONFIG_PATH="$WORK_DIR/sing-box-config" \
TACHYON_RESET_BIN_LOG="$WORK_DIR/bin.log" \
TACHYON_RESET_INIT_LOG="$WORK_DIR/init.log" \
  ucode -L "$WORK_DIR/lib" -L "$REAL_LIB" "$RESET_UC" reset-settings >"$WORK_DIR/result.json"
grep -Fxq 'start' "$WORK_DIR/init.log" ||
  fail "reset without no-start must start the service"

TACHYON_LIB="$WORK_DIR/lib" \
TACHYON_BIN="$WORK_DIR/fake-bin" \
TACHYON_SERVICE_INIT="$WORK_DIR/fake-init" \
TACHYON_CONFIG_PATH="$WORK_DIR/config" \
TACHYON_PERSISTENT_DIR="$WORK_DIR/persistent" \
TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/runtime" \
TACHYON_SING_BOX_TMP_DIR="$WORK_DIR/sing-box-tmp" \
TACHYON_SING_BOX_CONFIG_PATH="$WORK_DIR/sing-box-config" \
TACHYON_RESET_BIN_LOG="$WORK_DIR/bin.log" \
TACHYON_RESET_INIT_LOG="$WORK_DIR/init.log" \
  ucode -L "$WORK_DIR/lib" -L "$REAL_LIB" "$RESET_UC" bogus-mode 2>"$WORK_DIR/usage.err" &&
  fail "reset module must reject unknown modes"
grep -Fq 'Usage' "$WORK_DIR/usage.err" ||
  fail "reset module must print usage for unknown modes"

grep -Fq 'reset_settings [no-start]' "$TACHYON_BIN" ||
  fail "tachyon help must document reset_settings"
grep -Fq 'reset_settings' "$TACHYON_BIN" ||
  fail "tachyon failsafe dnsmasq restore must cover reset_settings"

# The installer must wipe leftover state on a fresh install but keep user
# configuration on upgrades and legacy migrations.
grep -Fq 'TACHYON_WAS_INSTALLED' "$INSTALLER" ||
  fail "installer must remember whether Tachyon was installed before"
grep -Fq 'reset_settings", "no-start"' "$INSTALLER" ||
  fail "installer post-install must delegate fresh-install defaults to reset_settings"
if grep -n -E 'reset_settings|TACHYON_WAS_INSTALLED' "$INSTALLER" | grep -qE 'rm -f |uci |sed -i '; then
  fail "installer must not own reset/state shell logic"
fi

printf 'reset settings contract checks passed\n'
