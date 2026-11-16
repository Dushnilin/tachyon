#!/usr/bin/env bash
# A tachyon-core replaced by hand must be configured for the version that is actually
# installed, rather than a stale /etc/tachyon/tachyon-core-version file.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -z "$TACHYON_LIB" ]; then
  if [ -d "$ROOT_DIR/tachyon/files/usr/lib/tachyon_core" ]; then
    TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
  else
    TACHYON_LIB="/usr/lib/tachyon"
  fi
fi

GEN="$TACHYON_LIB/tachyon_core/generator.uc"
RUNTIME_UC="$TACHYON_LIB/tachyon_core/runtime.uc"
for f in "$GEN" "$RUNTIME_UC"; do
  [ -f "$f" ] || fail "missing $f"
done

pass_count=0
ok() { pass_count=$((pass_count + 1)); }

LIVE_VERSION='0.5.7'
STALE_VERSION='0.3.2'

cat >"$WORK_DIR/tachyon-core" <<SH
#!/bin/sh
printf 'tachyon-core version $LIVE_VERSION\n\n'
printf 'Tags: with_quic\n'
SH
chmod 0755 "$WORK_DIR/tachyon-core"

printf '%s\n' "$STALE_VERSION" >"$WORK_DIR/tachyon-core-version"

detect() {
  PATH="$WORK_DIR:$PATH" \
  TACHYON_LIB="$TACHYON_LIB" \
  TACHYON_CORE_PREFLIGHT_BINARY="$WORK_DIR/tachyon-core" \
  TACHYON_CORE_VERSION_FILE="$WORK_DIR/tachyon-core-version" \
  TACHYON_UI_CORE_VERSION_CACHE_FILE="$WORK_DIR/missing-ui-cache" \
    ucode -L "$TACHYON_LIB" "$GEN" version-detect 2>/dev/null
}

# Stale state file, newer live binary on disk -> must report live binary version.
got="$(detect)"
[ "$got" = "$LIVE_VERSION" ] ||
  fail "stale state file must report the live binary ($LIVE_VERSION), got '$got'"
ok

# The stale file must be refreshed, or the next run reads it again.
refreshed="$(tr -d '\r\n' <"$WORK_DIR/tachyon-core-version")"
[ "$refreshed" = "$LIVE_VERSION" ] ||
  fail "the state file must be refreshed from the live probe, got '$refreshed'"
ok

# A binary that never answers must not hang config generation.
cat >"$WORK_DIR/tachyon-core" <<'SH'
#!/bin/sh
sleep 600
SH
chmod 0755 "$WORK_DIR/tachyon-core"

printf '%s\n' "$STALE_VERSION" >"$WORK_DIR/tachyon-core-version"
started="$(date +%s)"
got="$(detect)"
elapsed="$(( $(date +%s) - started ))"

[ "$elapsed" -lt 30 ] ||
  fail "a tachyon-core that never answers blocked the version probe for ${elapsed}s; the start would hang with it"
ok

# Nothing came back, so the recorded version is the fallback answer available.
[ "$got" = "$STALE_VERSION" ] ||
  fail "a hanging binary must fall back to the recorded version, got '$got'"
ok

# The probe has to be bounded in the source too, not merely fast on this machine.
probe_body="$(sed -n '/^function detect_core_version/,/^}/p' "$GEN")"
if ! grep -q 'bounded_command' <<<"$probe_body"; then
  fail "detect_core_version runs the binary without a time bound"
fi
ok

if grep -qE 'fs\.popen\(\[?"?tachyon-core version' <<<"$probe_body"; then
  fail "detect_core_version still opens the version command directly, with no bound on how long it may take"
fi
ok

# The retry has to match both store_rdrc deprecation forms.
grep -q 'store_rdrc cache file option is deprecated' "$RUNTIME_UC" ||
  fail "the store_rdrc retry must also match the deprecation notice form"
ok

grep -q 'experimental\\.cache_file\\.store_rdrc' "$RUNTIME_UC" ||
  fail "the store_rdrc retry must still match the option-path form"
ok

printf 'PASS: tachyon_core_version_live_probe (%d checks)\n' "$pass_count"
