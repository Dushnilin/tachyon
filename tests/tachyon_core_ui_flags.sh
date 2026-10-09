#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# tachyon-core is an engine variant in its own right: system-info, the ui
# capability flags and the sing-box check must all name it as such instead of
# guessing "tiny" or "stable" from a version number that is not in sing-box's
# series at all. The flags drive the updates dropdown and the diagnostics tab,
# so a wrong answer there is a wrong variant shown to the user.

SYSINFO_UC="$TACHYON_LIB/diagnostics/runtime.uc"
UI_UC="$TACHYON_LIB/service/ui.uc"

make_binary() {
  cat >"$WORK_DIR/sing-box" <<SH
#!/bin/sh
printf 'sing-box version $1\n\n'
printf 'Tags: with_quic,with_tailscale\n'
SH
  chmod 0755 "$WORK_DIR/sing-box"
}

json_int() {
  sed -n "s/.*\"$2\": *\([0-9][0-9]*\).*/\1/p" <<<"$1" | head -1
}

json_str() {
  sed -n "s/.*\"$2\": *\"\([^\"]*\)\".*/\1/p" <<<"$1" | head -1
}

system_info() {
  TACHYON_LIB="$TACHYON_LIB" \
  SB_VARIANT_STATE_FILE="$WORK_DIR/sing-box-variant" \
  SB_VERSION_STATE_FILE="$WORK_DIR/sing-box-version" \
  TACHYON_DIAGNOSTICS_SING_BOX_BIN_PATH="$WORK_DIR/sing-box" \
  TACHYON_SYSTEM_INFO_CACHE_FILE="$WORK_DIR/system-info.json" \
  TACHYON_SYSTEM_INFO_CACHE_TTL=0 \
  TACHYON_CONFIG_NAME=tachyon-tachyon-core-flags-test \
    ucode -L "$TACHYON_LIB" "$SYSINFO_UC" get-system-info
}

check_sing_box_json() {
  TACHYON_LIB="$TACHYON_LIB" \
  SB_VARIANT_STATE_FILE="$WORK_DIR/sing-box-variant" \
  SB_VERSION_STATE_FILE="$WORK_DIR/sing-box-version" \
  TACHYON_DIAGNOSTICS_SING_BOX_BIN_PATH="$WORK_DIR/sing-box" \
  TACHYON_CONFIG_NAME=tachyon-tachyon-core-flags-test \
    ucode -L "$TACHYON_LIB" "$SYSINFO_UC" check-sing-box
}

ui_capabilities() {
  PATH="$WORK_DIR:$PATH" \
  TACHYON_CONFIG_NAME=tachyon-tachyon-core-flags-test \
  TACHYON_UI_STATE_DIR="$WORK_DIR/state" \
  TACHYON_UI_SING_BOX_VERSION_CACHE_FILE="$WORK_DIR/sb-version-cache" \
  TACHYON_UI_SING_BOX_VARIANT_STATE_FILE="$WORK_DIR/sing-box-variant" \
  TACHYON_UI_SING_BOX_BIN_PATH="$WORK_DIR/sing-box" \
  ZAPRET_PROVIDER_NFQWS_BIN="$WORK_DIR/missing-nfqws" \
  ZAPRET2_PROVIDER_NFQWS2_BIN="$WORK_DIR/missing-nfqws2" \
  BYEDPI_BIN="$WORK_DIR/missing-ciadpi" \
    ucode -L "$TACHYON_LIB" "$UI_UC" get-ui-capabilities
}

rm -f "$WORK_DIR/sing-box-version"

# 1. Manual copy without a marker, stale "tiny" marker from a replaced binary:
#    the version suffix must win and the binary must not be labeled tiny.
printf 'tiny\n' >"$WORK_DIR/sing-box-variant"
make_binary 'v0.0.1-tachyon.0'
info="$(PATH="$WORK_DIR:$PATH" system_info)"
[ "$(json_int "$info" sing_box_tachyon_core)" = "1" ] ||
  fail "system-info must flag a tachyon-core version suffix as tachyon_core"
[ "$(json_int "$info" sing_box_tiny)" = "0" ] ||
  fail "a stale tiny marker must not reclassify tachyon-core as tiny"
[ "$(json_int "$info" sing_box_extended)" = "0" ] ||
  fail "tachyon-core must not be flagged as an extended fork"
[ "$(json_int "$info" sing_box_cert_pin)" = "1" ] ||
  fail "tachyon-core answers certificate_sha256 in the capability model"
url="$(json_str "$info" sing_box_repo_url)"
case "$url" in
  *Dushnilin/tachyon-core*) ;;
  *) fail "tachyon-core system-info must point at Dushnilin/tachyon-core, got '$url'" ;;
esac

# 2. Tailscale and FPTN are compiled into the core itself, so both flags
#    follow it without any build-tag probing.
rm -f "$WORK_DIR/sing-box-variant"
make_binary 'v0.0.1-tachyon.0'
rm -f "$WORK_DIR/system-info.json"
info="$(PATH="$WORK_DIR:$PATH" system_info)"
[ "$(json_int "$info" sing_box_tailscale)" = "1" ] ||
  fail "system-info must flag tailscale for tachyon-core without a build tag"
[ "$(json_int "$info" sing_box_fptn)" = "1" ] ||
  fail "system-info must flag fptn for tachyon-core"

# 3. The installer-written marker is the authority even over a version string
#    that has no suffix.
printf 'tachyon-core\n' >"$WORK_DIR/sing-box-variant"
make_binary 'v0.0.1-tachyon.0'
rm -f "$WORK_DIR/system-info.json"
info="$(PATH="$WORK_DIR:$PATH" system_info)"
[ "$(json_int "$info" sing_box_tachyon_core)" = "1" ] ||
  fail "the tachyon-core variant marker must flag tachyon_core"

# 4. The check must not run tachyon-core's own 0.x number through the upstream
#    1.12.4 gate - that gate used to mark a healthy core as incompatible.
rm -f "$WORK_DIR/sing-box-variant"
check="$(PATH="$WORK_DIR:$PATH" check_sing_box_json)"
[ "$(json_int "$check" sing_box_version_ok)" = "1" ] ||
  fail "tachyon-core version must pass the compatibility check"
[ "$(json_int "$check" sing_box_cert_pin)" = "1" ] ||
  fail "tachyon-core must report certificate pinning support in the check"
[ "$(json_int "$check" sing_box_extended)" = "0" ] ||
  fail "the check must not flag tachyon-core as an extended fork"

# 5. The ui capabilities feed the diagnostics tab and must agree.
printf 'tiny\n' >"$WORK_DIR/sing-box-variant"
make_binary 'v0.0.1-tachyon.0'
caps="$(ui_capabilities)"
[ "$(json_int "$caps" sing_box_tachyon_core)" = "1" ] ||
  fail "ui capabilities must flag tachyon_core"
[ "$(json_int "$caps" sing_box_tiny)" = "0" ] ||
  fail "ui capabilities must not flag tachyon-core as tiny despite the stale marker"
[ "$(json_int "$caps" sing_box_tailscale)" = "1" ] ||
  fail "ui capabilities must keep tailscale available for tachyon-core"
[ "$(json_int "$caps" sing_box_fptn)" = "1" ] ||
  fail "ui capabilities must flag fptn for tachyon-core"

# 6. A stock stable build must never pick up the new flags.
rm -f "$WORK_DIR/sing-box-variant"
make_binary '1.13.21'
rm -f "$WORK_DIR/system-info.json"
info="$(PATH="$WORK_DIR:$PATH" system_info)"
[ "$(json_int "$info" sing_box_tachyon_core)" = "0" ] ||
  fail "a stock sing-box must not be flagged as tachyon_core"
[ "$(json_int "$info" sing_box_fptn)" = "0" ] ||
  fail "a stock sing-box must not be flagged as fptn-capable"
[ "$(json_int "$info" sing_box_tiny)" = "0" ] ||
  fail "a stock sing-box with tags must not be flagged as tiny"

printf 'tachyon-core ui flag checks passed\n'
