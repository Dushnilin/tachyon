#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# The UI reads the tachyon-core version out of system-info.json. When no
# component action is running, the live binary probe must take precedence over a
# stale /etc/tachyon/tachyon-core-version state file.

RUNTIME_UC="$TACHYON_LIB/diagnostics/runtime.uc"

BIN_VERSION='0.5.7'
STATE_VERSION='0.3.1'

cat >"$WORK_DIR/tachyon-core" <<SH
#!/bin/sh
printf 'tachyon-core version $BIN_VERSION\n\n'
printf 'Tags: with_quic,with_tailscale\n'
SH
chmod 0755 "$WORK_DIR/tachyon-core"

printf '%s\n' "$STATE_VERSION" >"$WORK_DIR/tachyon-core-version"

system_info() {
  PATH="$WORK_DIR:$PATH" \
  TACHYON_LIB="$TACHYON_LIB" \
  TACHYON_CORE_VERSION_FILE="$WORK_DIR/tachyon-core-version" \
  TACHYON_CORE_BIN="$WORK_DIR/tachyon-core" \
  TACHYON_DIAGNOSTICS_CORE_BIN_PATH="$WORK_DIR/tachyon-core" \
  TACHYON_UI_COMPONENT_ACTION_DIR="$WORK_DIR/empty-actions" \
  TACHYON_SYSTEM_INFO_CACHE_FILE="$WORK_DIR/system-info.json" \
  TACHYON_SYSTEM_INFO_CACHE_TTL=0 \
  TACHYON_CONFIG_NAME=tachyon-core-version-source-test \
    ucode -L "$TACHYON_LIB" "$RUNTIME_UC" get-system-info
}

reported_version() {
  sed -n 's/.*"tachyon_core_version": *"\([^"]*\)".*/\1/p' <<<"$1"
}

rm -f "$WORK_DIR/system-info.json"
mkdir -p "$WORK_DIR/empty-actions"
info="$(system_info)"
got="$(reported_version "$info")"
[ "$got" = "$BIN_VERSION" ] ||
  fail "tachyon-core must report the live binary version ($BIN_VERSION), got '$got' (state file holds $STATE_VERSION)"

# Absent state file still works via live probe.
rm -f "$WORK_DIR/system-info.json"
rm -f "$WORK_DIR/tachyon-core-version"
no_state="$(system_info)"
got="$(reported_version "$no_state")"
[ "$got" = "$BIN_VERSION" ] ||
  fail "missing version state must fall back to the live probe, got '$got'"

printf 'tachyon-core version source checks passed\n'
