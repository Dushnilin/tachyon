#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# system-info, ui capabilities, and check-tachyon-core must report
# tachyon-core version, repo URL, cert_pin, tailscale, and fptn flags cleanly.

SYSINFO_UC="$TACHYON_LIB/diagnostics/runtime.uc"
UI_UC="$TACHYON_LIB/service/ui.uc"

make_binary() {
  cat >"$WORK_DIR/tachyon-core" <<SH
#!/bin/sh
printf 'tachyon-core version $1\n\n'
printf 'Tags: with_quic,with_tailscale\n'
SH
  chmod 0755 "$WORK_DIR/tachyon-core"
}

json_int() {
  sed -n "s/.*\"$2\": *\([0-9][0-9]*\).*/\1/p" <<<"$1" | head -1
}

json_str() {
  sed -n "s/.*\"$2\": *\"\([^\"]*\)\".*/\1/p" <<<"$1" | head -1
}

system_info() {
  TACHYON_LIB="$TACHYON_LIB" \
  TACHYON_CORE_VERSION_FILE="$WORK_DIR/tachyon-core-version" \
  TACHYON_CORE_BIN="$WORK_DIR/tachyon-core" \
  TACHYON_DIAGNOSTICS_CORE_BIN_PATH="$WORK_DIR/tachyon-core" \
  TACHYON_SYSTEM_INFO_CACHE_FILE="$WORK_DIR/system-info.json" \
  TACHYON_SYSTEM_INFO_CACHE_TTL=0 \
  TACHYON_CONFIG_NAME=tachyon-tachyon-core-flags-test \
    ucode -L "$TACHYON_LIB" "$SYSINFO_UC" get-system-info
}

check_tachyon_core_json() {
  TACHYON_LIB="$TACHYON_LIB" \
  TACHYON_CORE_VERSION_FILE="$WORK_DIR/tachyon-core-version" \
  TACHYON_CORE_BIN="$WORK_DIR/tachyon-core" \
  TACHYON_DIAGNOSTICS_CORE_BIN_PATH="$WORK_DIR/tachyon-core" \
  TACHYON_CONFIG_NAME=tachyon-tachyon-core-flags-test \
    ucode -L "$TACHYON_LIB" "$SYSINFO_UC" check-tachyon-core
}

ui_capabilities() {
  PATH="$WORK_DIR:$PATH" \
  TACHYON_CONFIG_NAME=tachyon-tachyon-core-flags-test \
  TACHYON_UI_STATE_DIR="$WORK_DIR/state" \
  TACHYON_UI_CORE_VERSION_CACHE_FILE="$WORK_DIR/core-version-cache" \
  TACHYON_UI_CORE_BIN_PATH="$WORK_DIR/tachyon-core" \
  ZAPRET_PROVIDER_NFQWS_BIN="$WORK_DIR/missing-nfqws" \
  ZAPRET2_PROVIDER_NFQWS2_BIN="$WORK_DIR/missing-nfqws2" \
  BYEDPI_BIN="$WORK_DIR/missing-ciadpi" \
    ucode -L "$TACHYON_LIB" "$UI_UC" get-ui-capabilities
}

rm -f "$WORK_DIR/tachyon-core-version"

# 1. Version suffix + repo URL + cert_pin + tailscale + fptn in system-info.
make_binary 'v0.5.7-tachyon.0'
info="$(PATH="$WORK_DIR:$PATH" system_info)"
[ "$(json_str "$info" active_engine)" = "tachyon-core" ] ||
  fail "system-info must report active_engine=tachyon-core"
[ "$(json_int "$info" tachyon_core_cert_pin)" = "1" ] ||
  fail "tachyon-core must report tachyon_core_cert_pin=1"
[ "$(json_int "$info" tachyon_core_tailscale)" = "1" ] ||
  fail "system-info must flag tailscale for tachyon-core"
[ "$(json_int "$info" tachyon_core_fptn)" = "1" ] ||
  fail "system-info must flag fptn for tachyon-core"
url="$(json_str "$info" tachyon_core_repo_url)"
case "$url" in
  *Dushnilin/tachyon-core*) ;;
  *) fail "tachyon-core system-info must point at Dushnilin/tachyon-core, got '$url'" ;;
esac

# 2. check-tachyon-core accepts 0.x versions cleanly.
check="$(PATH="$WORK_DIR:$PATH" check_tachyon_core_json)"
[ "$(json_int "$check" tachyon_core_version_ok)" = "1" ] ||
  fail "tachyon-core version must pass the compatibility check"
[ "$(json_int "$check" tachyon_core_cert_pin)" = "1" ] ||
  fail "tachyon-core must report certificate pinning support in the check"

# 3. ui capabilities agree.
caps="$(ui_capabilities)"
[ "$(json_int "$caps" tachyon_core_tailscale)" = "1" ] ||
  fail "ui capabilities must keep tailscale available for tachyon-core"
[ "$(json_int "$caps" tachyon_core_fptn)" = "1" ] ||
  fail "ui capabilities must flag fptn for tachyon-core"
[ "$(json_int "$caps" tachyon_core_cert_pin)" = "1" ] ||
  fail "ui capabilities must flag cert_pin for tachyon-core"

# 4. Real tachyon-core banner ("tachyon-core 0.5.7 (pure-Rust routing core)")
rm -f "$WORK_DIR/tachyon-core-version" "$WORK_DIR/system-info.json" "$WORK_DIR/core-version-cache"
cat >"$WORK_DIR/tachyon-core" <<'SH'
#!/bin/sh
printf 'tachyon-core 0.5.7 (pure-Rust routing core)\n'
printf 'Environment: linux/aarch64 (tachyon-core/rust)\n'
printf 'Tags: with_quic,with_tailscale,with_fptn\n'
SH
chmod 0755 "$WORK_DIR/tachyon-core"
info="$(PATH="$WORK_DIR:$PATH" system_info)"
[ "$(json_str "$info" tachyon_core_version)" = "0.5.7" ] ||
  fail "system-info must extract 0.5.7 from tachyon-core banner, got '$(json_str "$info" tachyon_core_version)'"
caps="$(ui_capabilities)"
[ "$(json_int "$caps" tachyon_core_fptn)" = "1" ] ||
  fail "ui capabilities must flag fptn for tachyon-core banner"

printf 'tachyon-core ui flag checks passed\n'
