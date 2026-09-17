#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
RESET_UC="$TACHYON_LIB/service/reset.uc"
TACHYON_BIN="$ROOT_DIR/tachyon/files/usr/bin/tachyon"
REAL_LIB="$ROOT_DIR/tachyon/files/usr/lib"
INSTALLER="$ROOT_DIR/install.sh"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -r "$RESET_UC" ] || fail "service/reset.uc must own reset-to-defaults logic"
[ -r "$TACHYON_BIN" ] || fail "tachyon entrypoint is missing"

grep -Fq 'reset_settings: [ "service/reset.uc", "reset-settings", 1 ]' "$TACHYON_BIN" ||
  fail "tachyon entrypoint must dispatch reset_settings to service/reset.uc"
grep -Fq 'reset_settings [no-start]' "$TACHYON_BIN" ||
  fail "tachyon help must document reset_settings"

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
  "$WORK_DIR/persistent/tailscale/server-main" \
  "$WORK_DIR/runtime" \
  "$WORK_DIR/sing-box-tmp"
printf '%s\n' stale >"$WORK_DIR/persistent/subscription-cache/cache.json"
printf '%s\n' stale >"$WORK_DIR/persistent/rulesets/community.srs"
printf '%s\n' identity >"$WORK_DIR/persistent/tailscale/server-main/node.key"
printf '%s\n' '{}' >"$WORK_DIR/sing-box-config"
printf '%s\n' custom >"$WORK_DIR/config"

: >"$WORK_DIR/bin.log"
: >"$WORK_DIR/init.log"
cat >"$WORK_DIR/fake-bin" <<'SH'
#!/usr/bin/env sh
printf '%s\n' "$*" >> "$TACHYON_RESET_BIN_LOG"
exit 0
SH
cat >"$WORK_DIR/fake-init" <<'SH'
#!/usr/bin/env sh
printf '%s\n' "$*" >> "$TACHYON_RESET_INIT_LOG"
exit 0
SH
chmod 0755 "$WORK_DIR/fake-bin" "$WORK_DIR/fake-init"

run_reset() {
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
    ucode -L "$WORK_DIR/lib" -L "$REAL_LIB" "$RESET_UC" reset-settings "$@"
}

run_reset no-start >"$WORK_DIR/result.json"
grep -Fq '"success":true' "$WORK_DIR/result.json" || fail "reset-settings must report success"
grep -Fxq 'stop' "$WORK_DIR/bin.log" || fail "reset must stop through backend entrypoint"
grep -Fxq 'stop' "$WORK_DIR/init.log" || fail "reset must stop through init.d"
if grep -Fxq 'start' "$WORK_DIR/init.log"; then fail "no-start reset must not start service"; fi
cmp -s "$WORK_DIR/config" "$WORK_DIR/default-config" || fail "reset must restore factory config"
[ "$(ucode -e "let fs = require('fs'); printf('%o', fs.stat('$WORK_DIR/config').mode & 511);")" = "600" ] ||
  fail "reset config must be chmod 600"
[ ! -e "$WORK_DIR/persistent/subscription-cache" ] || fail "reset must clear subscription cache"
[ ! -e "$WORK_DIR/persistent/rulesets" ] || fail "reset must clear ruleset cache"
[ "$(cat "$WORK_DIR/persistent/tailscale/server-main/node.key")" = identity ] || fail "reset must preserve Tailscale identity"
[ ! -e "$WORK_DIR/runtime" ] || fail "reset must clear runtime state"
[ ! -e "$WORK_DIR/sing-box-tmp" ] || fail "reset must clear sing-box temporary state"
[ ! -e "$WORK_DIR/sing-box-config" ] || fail "reset must remove generated sing-box config"

# Installer v3 preserves configuration and delegates package initialization to
# package hooks/runtime modules. It must never implement reset semantics itself.
grep -Fq 'snapshot_state()' "$INSTALLER" || fail "installer must snapshot config before package changes"
grep -Fq 'TACHYON_WAS_INSTALLED' "$INSTALLER" || fail "installer must remember previous install state"
if grep -n -E '(^|[;&|[:space:]])uci[[:space:]]+-q|sed -i .*/etc/config/tachyon' "$INSTALLER" >/dev/null; then
  fail "installer shell must not own UCI reset/mutation logic"
fi

printf 'reset settings contract checks passed\n'
