#!/usr/bin/env bash
# Verifies tachyon-core profile, capability gates, certificate pinning, and TLS
# unknown-field repair paths.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"
RT="$LIB_DIR/tachyon_core/runtime.uc"
VAL="$LIB_DIR/config/validator.uc"
GEN="$LIB_DIR/tachyon_core/generator.uc"
[ -f "$RT" ] || fail "tachyon_core/runtime.uc not found"
[ -f "$VAL" ] || fail "config/validator.uc not found"
[ -f "$GEN" ] || fail "tachyon_core/generator.uc not found"

CORE_VERSION="v0.5.7"

rt() {
    if ucode -L "$LIB_DIR" "$RT" "$@" >/dev/null 2>&1; then echo yes; else echo no; fi
}

# ─── core-profile resolves to tachyon-core ───────────────────────────────────
prof="$(ucode -L "$LIB_DIR" "$RT" core-profile "$CORE_VERSION" 2>/dev/null)"
[ "$prof" = "tachyon-core" ] || fail "core-profile must resolve to tachyon-core, got '$prof'"

# ─── xhttp and cert-pin are always supported on tachyon-core ─────────────────
out="$(rt supports-xhttp "$CORE_VERSION" "tachyon-core version $CORE_VERSION")"
[ "$out" = "yes" ] || fail "tachyon-core implements xhttp but reported '$out'"

out="$(rt supports-cert-pin "$CORE_VERSION")"
[ "$out" = "yes" ] || fail "tachyon-core supports certificate pinning"

# ─── certificate pinning field & tls repair ──────────────────────────────────
grep -q 'tls\[pin_field\]' "$LIB_DIR/tachyon_core/generator_outbounds.uc" \
  || fail "outbound generation must write tls[pin_field]"

grep -Fq '\.tls\.(\w+)\.(\w+): json: unknown field' "$RT" \
  || fail "the repair loop must keep a pattern for unknown fields inside tls.*"
grep -q 'delete item.tls\[container\]\[unknown_field\]' "$RT" \
  || fail "the tls repair path must delete the offending field"
grep -q 'certificate_sha256' "$RT" \
  || fail "the existing certificate_sha256 repair path is gone"

# ─── generator schema gates stay open for tachyon-core ───────────────────────
gate() {
  ucode -L "$LIB_DIR" "$GEN" "$1" "$CORE_VERSION" >/dev/null 2>&1 && echo yes || echo no
}

out="$(gate is-sb-1-14-plus)"
[ "$out" = "yes" ] || fail "1.14 schema gate must be open for tachyon-core: $out"

out="$(gate is-sb-1-15-plus)"
[ "$out" = "yes" ] || fail "1.15 schema gate must be open for tachyon-core: $out"

out="$(ucode -L "$LIB_DIR" "$GEN" certificate-pin-field "$CORE_VERSION" 2>/dev/null)"
[ "$out" = "certificate_sha256" ] \
  || fail "tachyon-core pin field must be certificate_sha256, got '$out'"

printf 'fault: tachyon-core compatibility checks passed\n'
