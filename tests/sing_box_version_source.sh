#!/usr/bin/env bash
set -eo pipefail

# The UI reads the sing-box version out of system-info.json, which used to prefer
# /etc/tachyon/sing-box-version for every "extended" install. That state file is
# written by the component action alone, so a sing-box installed through install.sh,
# opkg or by hand left it pinned at whatever the last component action wrote — the
# dashboard reported an old version indefinitely and the update badge compared
# against it. The state file is only a fallback for variants whose binary cannot be
# executed to print a version: extended-compressed (a self-extracting stub) and lx.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
RUNTIME_UC="$TACHYON_LIB/diagnostics/runtime.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

BIN_VERSION='1.13.18-extended-2.6.3'
STATE_VERSION='1.13.16-extended-2.6.2'

cat >"$WORK_DIR/sing-box" <<SH
#!/bin/sh
printf 'sing-box version $BIN_VERSION\n\n'
printf 'Tags: with_quic,with_tailscale\n'
SH
chmod 0755 "$WORK_DIR/sing-box"

printf '%s\n' "$STATE_VERSION" >"$WORK_DIR/sing-box-version"

system_info() {
  local variant="$1"
  printf '%s\n' "$variant" >"$WORK_DIR/sing-box-variant"
  PATH="$WORK_DIR:$PATH" \
  TACHYON_LIB="$TACHYON_LIB" \
  SB_VARIANT_STATE_FILE="$WORK_DIR/sing-box-variant" \
  SB_VERSION_STATE_FILE="$WORK_DIR/sing-box-version" \
  TACHYON_DIAGNOSTICS_SING_BOX_BIN_PATH="$WORK_DIR/sing-box" \
  TACHYON_SYSTEM_INFO_CACHE_FILE="$WORK_DIR/system-info.json" \
  TACHYON_SYSTEM_INFO_CACHE_TTL=0 \
  TACHYON_CONFIG_NAME=tachyon-sing-box-version-test \
    ucode -L "$TACHYON_LIB" "$RUNTIME_UC" get-system-info
}

reported_version() {
  sed -n 's/.*"sing_box_version": *"\([^"]*\)".*/\1/p' <<<"$1"
}

# Plain `extended`: the binary answers, so the stale state file must not win.
rm -f "$WORK_DIR/system-info.json"
extended="$(system_info extended)"
got="$(reported_version "$extended")"
[ "$got" = "$BIN_VERSION" ] ||
  fail "extended sing-box must report the live binary version, got '$got' (state file holds $STATE_VERSION)"

# extended-compressed cannot be executed for a version, so the state file stands.
rm -f "$WORK_DIR/system-info.json"
compressed="$(system_info extended-compressed)"
got="$(reported_version "$compressed")"
[ "$got" = "$STATE_VERSION" ] ||
  fail "extended-compressed sing-box must report the recorded state version, got '$got'"

# ...but an absent state must fall through to the live probe rather than "unknown":
# nothing writes the state except the component action.
rm -f "$WORK_DIR/system-info.json"
mv "$WORK_DIR/sing-box-version" "$WORK_DIR/sing-box-version.bak"
no_state="$(system_info extended-compressed)"
got="$(reported_version "$no_state")"
[ "$got" = "$BIN_VERSION" ] ||
  fail "missing version state must fall back to the live probe, got '$got'"
mv "$WORK_DIR/sing-box-version.bak" "$WORK_DIR/sing-box-version"

# Structural: the gate must never list plain `extended` again.
gate="$(sed -n '/^function sing_box_live_probe_disabled/,/^}/p' "$RUNTIME_UC")"
[ -n "$gate" ] || fail "diagnostics/runtime.uc must define sing_box_live_probe_disabled"
if grep -Fq 'sing_box_marker_is("extended")' <<<"$gate"; then
  fail "sing_box_live_probe_disabled must not cover plain extended; its binary reports its own version"
fi
grep -Fq 'sing_box_marker_is("extended-compressed")' <<<"$gate" ||
  fail "sing_box_live_probe_disabled must still cover extended-compressed"
grep -Fq 'sing_box_marker_is("lx")' <<<"$gate" ||
  fail "sing_box_live_probe_disabled must still cover lx"

printf 'sing-box version source checks passed\n'
