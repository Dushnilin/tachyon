#!/usr/bin/env bash
# A sing-box replaced by hand must be configured for the version that is actually
# installed.
#
# /etc/tachyon/sing-box-version is written by the component action alone. It used to
# be the source of truth for the generator, so replacing the binary by hand - or
# through install.sh or opkg - left the file at whatever the last component action
# wrote. The generator then configured for that stale version: stock 1.13.21 state
# plus a live 1.15.0-alpha.10 binary produced cache_file.store_rdrc, and 1.15
# refused to start with "store_rdrc cache file option is deprecated", so Tachyon
# never came up. Installing Tachyon after sing-box worked, because the file did not
# exist yet and the probe ran.
#
# The file is a fallback only for the variants whose binary cannot be executed for a
# version string: extended-compressed (a self-extracting stub) and lx.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -z "$TACHYON_LIB" ]; then
  if [ -d "$ROOT_DIR/tachyon/files/usr/lib/singbox" ]; then
    TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
  else
    TACHYON_LIB="/usr/lib/tachyon"
  fi
fi

GEN="$TACHYON_LIB/singbox/generator.uc"
RUNTIME_UC="$TACHYON_LIB/singbox/runtime.uc"
for f in "$GEN" "$RUNTIME_UC"; do
  [ -f "$f" ] || fail "missing $f"
done

pass_count=0
ok() { pass_count=$((pass_count + 1)); }

LIVE_VERSION='1.15.0-alpha.10'
STALE_VERSION='1.13.21'

cat >"$WORK_DIR/sing-box" <<SH
#!/bin/sh
printf 'sing-box version $LIVE_VERSION\n\n'
printf 'Tags: with_quic\n'
SH
chmod 0755 "$WORK_DIR/sing-box"

printf '%s\n' "$STALE_VERSION" >"$WORK_DIR/sing-box-version"

detect() { # <marker>
  printf '%s\n' "$1" >"$WORK_DIR/sing-box-variant"
  PATH="$WORK_DIR:$PATH" \
  TACHYON_LIB="$TACHYON_LIB" \
  SB_VARIANT_STATE_FILE="$WORK_DIR/sing-box-variant" \
  SB_VERSION_STATE_FILE="$WORK_DIR/sing-box-version" \
    ucode -L "$TACHYON_LIB" "$GEN" version-detect 2>/dev/null
}

# The reported case: marker stable, stale state, newer binary on disk.
got="$(detect stable)"
[ "$got" = "$LIVE_VERSION" ] ||
  fail "marker stable with a stale state file must report the live binary ($LIVE_VERSION), got '$got'"

# 1.15 is what makes the difference: 1.13.21 state meant is_sb_1_14_plus was false
# and the generator wrote store_rdrc.
if PATH="$WORK_DIR:$PATH" TACHYON_LIB="$TACHYON_LIB" \
   SB_VARIANT_STATE_FILE="$WORK_DIR/sing-box-variant" \
   SB_VERSION_STATE_FILE="$WORK_DIR/sing-box-version" \
   ucode -L "$TACHYON_LIB" "$GEN" is-sb-1-14-plus; then
  ok
else
  fail "a live 1.15.0-alpha.10 binary must be detected as 1.14+; the stale 1.13.21 state file decided otherwise"
fi

# The stale file must be refreshed, or the next run reads it again.
refreshed="$(tr -d '\r\n' <"$WORK_DIR/sing-box-version")"
[ "$refreshed" = "$LIVE_VERSION" ] ||
  fail "the state file must be refreshed from the live probe, got '$refreshed'"

# Variants whose binary cannot be executed keep using the recorded version.
for marker in lx extended-compressed; do
  printf '%s\n' "$STALE_VERSION" >"$WORK_DIR/sing-box-version"
  got="$(detect "$marker")"
  [ "$got" = "$STALE_VERSION" ] ||
    fail "marker $marker cannot be probed for a version, so the recorded one must stand, got '$got'"
done

# ...and with no recorded version they must still fall through to the probe.
rm -f "$WORK_DIR/sing-box-version"
got="$(detect lx)"
[ "$got" = "$LIVE_VERSION" ] ||
  fail "marker lx with no recorded version must fall back to the live probe, got '$got'"

# A binary that never answers must not take the start with it. The live probe became
# the default path in 1.4.9, so an unbounded pop( here would hang every config
# generation on a stub that unpacks, a wrapper that waits, or a half-written file.
cat >"$WORK_DIR/sing-box" <<'SH'
#!/bin/sh
sleep 600
SH
chmod 0755 "$WORK_DIR/sing-box"

printf '%s\n' "$STALE_VERSION" >"$WORK_DIR/sing-box-version"
printf 'stable' >"$WORK_DIR/sing-box-variant"
started="$(date +%s)"
got="$(detect stable)"
elapsed="$(( $(date +%s) - started ))"

[ "$elapsed" -lt 30 ] ||
  fail "a sing-box that never answers blocked the version probe for ${elapsed}s; the start would hang with it"
ok

# Nothing came back, so the recorded version is the only answer available.
[ "$got" = "$STALE_VERSION" ] ||
  fail "a hanging binary must fall back to the recorded version, got '$got'"
ok

# The probe has to be bounded in the source too, not merely fast on this machine.
probe_body="$(sed -n '/^function detect_sing_box_version/,/^}/p' "$GEN")"
if ! grep -q 'bounded_command' <<<"$probe_body"; then
  fail "detect_sing_box_version runs the binary without a time bound"
fi
ok

if grep -qE 'fs\.popen\(\[?"?sing-box version' <<<"$probe_body"; then
  fail "detect_sing_box_version still opens the version command directly, with no bound on how long it may take"
fi
ok

# The retry has to match the message 1.14+ actually prints. It does not carry the
# option path, so matching only "experimental.cache_file.store_rdrc" missed it and
# the start died on [fatal] instead of retrying with store_dns.
grep -q 'store_rdrc cache file option is deprecated' "$RUNTIME_UC" ||
  fail "the store_rdrc retry must also match the deprecation notice sing-box 1.14+ prints"
ok

grep -q 'experimental\\.cache_file\\.store_rdrc' "$RUNTIME_UC" ||
  fail "the store_rdrc retry must still match the option-path form"
ok

printf 'PASS: sing_box_version_live_probe\n'