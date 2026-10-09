#!/usr/bin/env bash
# Tachyon's own sing-box-compatible core must work, and nothing it does not
# implement may be switched on in its name.
#
# The core prints `sing-box version v<version>-tachyon.<n>` when it is invoked
# under the name sing-box, and that suffix is the only thing identifying it: it
# prints no build tags, so every capability that used to be probed from the
# banner has to answer from the suffix instead. Three consequences pull in
# opposite directions and each one is a way to break a router:
#
#   - its version is NOT a sing-box version. "0.0.1-tachyon.0" is not older than
#     sing-box 1.12, it is a different project with no release number in that
#     series, and the minimum-version gate used to refuse to start at all.
#   - the suffix carries no schema level, so nothing may be enabled because of it.
#   - it implements xhttp but says nothing about build tags, so the tag probe
#     answers "no" and xhttp nodes leave a subscription without a warning.
#
# Driven through the real CLI modes, not by reading the source.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"
RT="$LIB_DIR/singbox/runtime.uc"
VAL="$LIB_DIR/config/validator.uc"
[ -f "$RT" ] || fail "singbox/runtime.uc not found"
[ -f "$VAL" ] || fail "config/validator.uc not found"

CORE_VERSION="v0.0.1-tachyon.0"

# runtime <op> <args...> -> prints yes/no, matching the exit-code convention
# the other modes in this module already use.
rt() {
    if ucode -L "$LIB_DIR" "$RT" "$@" >/dev/null 2>&1; then echo yes; else echo no; fi
}

# ─── it is recognised as itself, not as stable sing-box ───────────────────────
out="$(rt is-foreign-core "$CORE_VERSION")"
[ "$out" = "yes" ] || fail "the core's version string is not recognised as a foreign core: $out"

out="$(rt is-foreign-core "1.14.2-lx.11")"
[ "$out" = "no" ] || fail "an lx version was mistaken for the core: $out"

out="$(rt is-foreign-core "1.14.2")"
[ "$out" = "no" ] || fail "an upstream version was mistaken for the core: $out"

out="$(rt is-foreign-core "1.13.18-extended-2.6.3")"
[ "$out" = "no" ] || fail "an extended version was mistaken for the core: $out"

# ─── xhttp is implemented, and the tag probe cannot see it ───────────────────
# With the build-tag probe left in place this answers "no" and every xhttp node
# is dropped from a subscription: a silent loss of the nodes a user paid for.
out="$(rt supports-xhttp "$CORE_VERSION" "sing-box version $CORE_VERSION")" \
 
[ "$out" = "yes" ] \
  || fail "the core implements xhttp but is reported as not supporting it, so its nodes are dropped silently"

# ─── certificate pinning works, under the field the core accepts ──────────────
# The core has no certificate_sha256 anywhere - the string does not occur in its
# config crate - but certificate_public_key_sha256 is in its TLS allowlist. The
# two hash different things (whole DER vs public key), so this is a field choice,
# not a rename, and the generator has to write the one the build understands.
out="$(rt supports-cert-pin "$CORE_VERSION")"
[ "$out" = "yes" ] \
  || fail "the core accepts certificate_public_key_sha256, so pinning must be available to it"

# A higher numeric prefix must not change the answer either: the field is decided
# by the marker, not by the version number.
out="$(rt supports-cert-pin "v1.15.0-tachyon.0")"
[ "$out" = "yes" ] \
  || fail "a higher numeric prefix changed pinning for the core, which is decided by the marker"

# Upstream must be unaffected by any of the above.
out="$(rt supports-cert-pin "1.15.0")"
[ "$out" = "yes" ] || fail "pinning stopped working for sing-box 1.15 itself"

# And the generator must not hand the core a field it rejects.
GEN="$LIB_DIR/singbox/generator.uc"
grep -q 'certificate_public_key_sha256' "$GEN" \
  || fail "the generator has no public-key pin field, so the core's pins cannot be written"
grep -q 'tls\[pin_field\]' "$LIB_DIR/singbox/generator_outbounds.uc" \
  || fail "outbound generation still hardcodes certificate_sha256, which the core rejects"

out="$(rt supports-xhttp "1.14.2" "sing-box version 1.14.2")"
[ "$out" = "no" ] || fail "plain sing-box without the build tag must still report no xhttp"

# ─── the minimum-version gate must not fire on a foreign number ──────────────
# The gate is the one that refused to start the router at all. Compared through
# the same code path the validator uses.
out="$(ucode -L "$LIB_DIR" "$LIB_DIR/core/helpers.uc" version-at-least "$CORE_VERSION" 1.12.0 2>/dev/null && echo yes || echo no)"
[ "$out" = "no" ] \
  || fail "the core's own version must not satisfy the sing-box minimum; if it does, a gate somewhere else is comparing two different series"

if ! grep -q 'sing_box_version_is_foreign_core(sing_box_version)' "$VAL"; then
  fail "the validator still applies the sing-box minimum to a foreign core version and will refuse to start"
fi
if ! grep -q 'sing_box_version_is_foreign_core' "$RT"; then
  fail "singbox/runtime.uc no longer carries the foreign-core predicate"
fi

# ─── an unknown nested tls field must be repairable ─────────────────────────
# Every existing repair pattern matches a single top-level key, so
# outbounds[N].tls.reality.<field> used to reach the bottom of the retry loop
# with nothing stripped: the check failed, the retry gave up, and one node took
# the whole proxy down instead of losing that one node.
grep -Fq '\.tls\.(\w+)\.(\w+): json: unknown field' "$RT"   || fail "the repair loop still has no pattern for unknown fields inside tls.*; a single node can take the proxy down"
grep -q 'delete item.tls\[container\]\[unknown_field\]' "$RT" \
  || fail "the tls repair path does not actually delete the offending field"

# The certificate_sha256 repair must keep working - it is the same mechanism and
# a previous fix depended on it.
grep -q 'certificate_sha256' "$RT" \
  || fail "the existing certificate_sha256 repair path is gone"

printf 'fault: tachyon-core compatibility checks passed\n'
# ─── every version gate is open: the core's schema has each of these fields ───
# The gates exist because an unknown field is a hard rejection that takes the
# whole config down. Checked against the core's own validator rather than its
# README, since the README is a claim and validate.rs is the rule:
# http_clients, route.default_http_client and dns.optimistic are accepted,
# cache_file carries store_dns, buffer_size and flush_interval, and the TLS
# allowlist carries certificate_sha256.
GEN="$LIB_DIR/singbox/generator.uc"

gate() {
  ucode -L "$LIB_DIR" "$GEN" "$1" "$CORE_VERSION" >/dev/null 2>&1 && echo yes || echo no
}

out="$(gate is-sb-1-14-plus)"
[ "$out" = "yes" ] \
  || fail "the core implements dns.optimistic, http_clients and store_dns, so the 1.14 gate must be open: $out"

out="$(gate is-sb-1-15-plus)"
[ "$out" = "yes" ] \
  || fail "the core implements cache buffer_size and flush_interval, so the 1.15 gate must be open: $out"

out="$(ucode -L "$LIB_DIR" "$GEN" certificate-pin-field "$CORE_VERSION" 2>/dev/null)"
[ "$out" = "certificate_sha256" ] \
  || fail "the core accepts certificate_sha256, which is the field a pcs is: got '$out'"

# And the gates must still close for a build that lacks the fields.
if ucode -L "$LIB_DIR" "$GEN" is-sb-1-15-plus "1.14.2" >/dev/null 2>&1; then
  fail "stock 1.14.2 has no buffer_size and the gate must stay shut"
fi
out="$(ucode -L "$LIB_DIR" "$GEN" certificate-pin-field "1.14.2-lx.12" 2>/dev/null)"
[ "$out" = "certificate_public_key_sha256" ] \
  || fail "lx rejects certificate_sha256, so it must get the public-key field: got '$out'"
