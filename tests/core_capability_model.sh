#!/bin/sh
# The capability model is the one place that decides what a sing-box build is and
# what it accepts. These checks are the model answering for every core we ship,
# so a change to one table cannot quietly change what the generator emits.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB_DIR="$ROOT_DIR/tachyon/files/usr/lib"
RT="$LIB_DIR/singbox/runtime.uc"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

pass_count=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { pass_count=$((pass_count + 1)); }

rt() { ucode -L "$LIB_DIR" "$RT" "$@"; }

# ─── profile resolution ──────────────────────────────────────────────────────
# The marker file is authoritative when a build does not name itself, and the
# version pattern decides when it does.
check_profile() {
    version="$1"; marker="$2"; want="$3"
    got="$(rt core-profile "$version" "$marker")"
    [ "$got" = "$want" ] || fail "core-profile $version/$marker is $got, want $want"
    ok
}

check_profile "1.15.0" "" "upstream"
check_profile "v1.16.1" "" "upstream"
check_profile "1.14.2-lx.12" "" "lx"
check_profile "1.13.18-extended" "" "extended"
# Not plain "extended": the compressed build has capabilities of its own, so an
# unmarked binary must not be assumed to be the compressed one.
check_profile "1.13.18-extended-compressed" "" "extended-compressed"
check_profile "0.0.1-tachyon.0" "" "tachyon-core"
# The lite build was cancelled: its suffix claims nothing, least of all the
# full core's profile.
check_profile "0.0.1-tachyon-lite.0" "" "upstream"
# The marker wins over the version string, which is what makes a swapped package
# read as what it is now rather than what it was called before.
check_profile "1.13.21" "extended" "extended"
check_profile "1.13.21" "extended-compressed" "extended-compressed"
# A bare number is not an identity. Nothing may be concluded from "0.0.1" alone.
check_profile "0.0.1" "" "upstream"

# ─── a stale marker file must not overrule the binary ────────────────────────
# Found on a test router: the binary had been swapped for tachyon-core while
# /etc/tachyon/sing-box-variant still read "lx", left over from the install
# before it. The file describes what was installed previously, so a build that
# names itself wins - otherwise a foreign core is handed the lx profile, with a
# wrong pin field and a wrong schema level and no error anywhere.
mkdir -p "$WORK_DIR/state"
printf 'lx\n' >"$WORK_DIR/state/sing-box-variant"
printf 'v0.0.1-tachyon.0\n' >"$WORK_DIR/state/sing-box-version"

stale() {
    SB_VARIANT_STATE_FILE="$WORK_DIR/state/sing-box-variant" \
    SB_VERSION_STATE_FILE="$WORK_DIR/state/sing-box-version" \
    "$@"
}

got="$(stale ucode -L "$LIB_DIR" "$RT" core-profile "v0.0.1-tachyon.0")"
[ "$got" = "tachyon-core" ] \
    || fail "a version naming tachyon-core must outrank a stale lx marker, got '$got'"
ok

got="$(stale ucode -L "$LIB_DIR" "$RT" core-pin-field "v0.0.1-tachyon.0")"
[ "$got" = "certificate_sha256" ] \
    || fail "a stale lx marker made a foreign core emit the lx pin field, got '$got'"
ok

# The marker is still the authority for a build that does not name itself.
printf 'extended\n' >"$WORK_DIR/state/sing-box-variant"
printf '1.13.21\n' >"$WORK_DIR/state/sing-box-version"
got="$(stale ucode -L "$LIB_DIR" "$RT" core-profile "1.13.21")"
[ "$got" = "extended" ] \
    || fail "the marker must still decide for a build that does not name itself, got '$got'"
ok

# ─── the real banner ────────────────────────────────────────────────────────
# The released v0.0.1 prints "tachyon-core 0.0.1" - no fork suffix - so
# sing_box_version() yields a bare "0.0.1" that is indistinguishable from a stock
# build of the same number. The name in the banner is the only thing that tells
# them apart, and without it the minimum-version gate compares 0.0.1 against 1.12
# and refuses to start the router.
FAKE_BIN="$WORK_DIR/fakebin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/sing-box" <<'FAKE'
#!/bin/sh
echo "tachyon-core 0.0.1"
FAKE
chmod +x "$FAKE_BIN/sing-box"

with_fake_core() {
    PATH="$FAKE_BIN:$PATH" "$@"
}

got="$(with_fake_core ucode -L "$LIB_DIR" "$RT" core-profile "")"
[ "$got" = "tachyon-core" ] \
    || fail "a live 'tachyon-core 0.0.1' banner must resolve to tachyon-core, got '$got'"
ok

got="$(with_fake_core ucode -L "$LIB_DIR" "$RT" core-pin-field "")"
[ "$got" = "certificate_sha256" ] \
    || fail "the real core accepts certificate_sha256, got '$got'"
ok

# The gate that used to refuse to start the router: a foreign number must not be
# compared against the sing-box minimum as if it were one.
with_fake_core ucode -L "$LIB_DIR" "$RT" is-foreign-core "" \
    || fail "the live core must be recognised as a foreign core"
ok

cat > "$FAKE_BIN/sing-box" <<'FAKE'
#!/bin/sh
echo "sing-box 1.15.0 linux-amd64"
FAKE
got="$(with_fake_core ucode -L "$LIB_DIR" "$RT" core-profile "")"
[ "$got" = "upstream" ] \
    || fail "a stock sing-box banner must not be read as our core, got '$got'"
ok
rm -rf "$FAKE_BIN"

# ─── the TLS pin field ───────────────────────────────────────────────────────
# certificate_sha256 and certificate_public_key_sha256 are different values, so
# this is a field choice per build and never a substitution.
check_pin() {
    version="$1"; marker="$2"; want="$3"
    got="$(rt core-pin-field "$version" "$marker" || true)"
    [ "$got" = "$want" ] || fail "core-pin-field $version/$marker is '$got', want '$want'"
    ok
}

check_pin "1.15.0" "" "certificate_sha256"
check_pin "v1.16.1" "" "certificate_sha256"
# 1.14.2 upstream predates the field; lx has the public-key one instead.
check_pin "1.14.2" "" ""
check_pin "1.14.2-lx.12" "" "certificate_public_key_sha256"
check_pin "0.0.1-tachyon.0" "" "certificate_sha256"
check_pin "0.0.1-tachyon-lite.0" "" ""
# A bare variant name carries no version, so nothing may be concluded from it.
check_pin "sing-box-lx" "" ""

# ─── schema gates ───────────────────────────────────────────────────────────
# The core's own version sorts below every 1.x, so its schema answer is a fact
# about the core and not a reading of its number.
check_gate() {
    version="$1"; gate="$2"; want="$3"
    if rt "core-$gate" "$version"; then got=yes; else got=no; fi
    [ "$got" = "$want" ] || fail "core-$gate $version is $got, want $want"
    ok
}

check_gate "1.13.0" "has-1-14" no
check_gate "1.14.2" "has-1-14" yes
check_gate "1.14.2" "has-1-15" no
check_gate "1.15.0" "has-1-15" yes
check_gate "1.14.2-lx.12" "has-1-15" no
check_gate "0.0.1-tachyon.0" "has-1-14" yes
check_gate "0.0.1-tachyon.0" "has-1-15" yes
check_gate "0.0.1-tachyon-lite.0" "has-1-15" no

# ─── protocols per core ─────────────────────────────────────────────────────
# This is the point of the table: every core states what it can do, so the
# interface can grey out an action instead of letting apply produce a config the
# core will reject.
for proto in awg fptn cloudflared openconnect bridge; do
    rt core-supports-protocol "$proto" "0.0.1-tachyon.0" "" \
        || fail "tachyon-core must support $proto"
    ok
done
# Upstream sing-box has no fork features; awg and fptn are not among them.
if rt core-supports-protocol "awg" "1.15.0" ""; then
    fail "upstream sing-box must not claim awg, which is a fork feature"
fi
if rt core-supports-protocol "fptn" "1.15.0" ""; then
    fail "upstream sing-box must not claim fptn, which is our core's feature"
fi
# The protocol every core Tachyon drives has to have.
for version in 1.15.0 1.14.2-lx.12 0.0.1-tachyon.0; do
    for proto in vless trojan hysteria2 shadowsocks; do
        rt core-supports-protocol "$proto" "$version" "" \
            || fail "$version must support $proto"
        ok
    done
done

# ─── the whole answer, in one object ─────────────────────────────────────────
caps="$(rt core-capabilities "0.0.1-tachyon.0" "")"
case "$caps" in
    *'"profile": "tachyon-core"'*) ok ;;
    *) fail "capabilities did not report the tachyon-core profile: $caps" ;;
esac
case "$caps" in
    *'"cert_pin": true'*) ok ;;
    *) fail "capabilities did not report cert_pin for a core that accepts it: $caps" ;;
esac
case "$caps" in
    *'"foreign_series": 1'*) ok ;;
    *) fail "capabilities must mark the core's version as a foreign series: $caps" ;;
esac

# Stock upstream is the other series, and its number is comparable.
caps="$(rt core-capabilities "1.15.0" "")"
case "$caps" in
    *'"foreign_series": 0'*) ok ;;
    *) fail "upstream must not be marked a foreign series: $caps" ;;
esac

echo "ok - $pass_count checks passed"