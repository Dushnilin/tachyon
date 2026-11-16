#!/bin/sh
# The capability model answers for tachyon-core so config generation and UI
# capabilities stay consistent.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB_DIR="$ROOT_DIR/tachyon/files/usr/lib"
RT="$LIB_DIR/tachyon_core/runtime.uc"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

pass_count=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { pass_count=$((pass_count + 1)); }

rt() { ucode -L "$LIB_DIR" "$RT" "$@"; }

# ─── profile resolution ──────────────────────────────────────────────────────
check_profile() {
    version="$1"; marker="$2"; want="$3"
    got="$(rt core-profile "$version" "$marker")"
    [ "$got" = "$want" ] || fail "core-profile $version/$marker is $got, want $want"
    ok
}

check_profile "0.5.7" "" "tachyon-core"
check_profile "v0.5.7" "" "tachyon-core"
check_profile "0.0.1-tachyon.0" "" "tachyon-core"
check_profile "" "tachyon-core" "tachyon-core"

# ─── the real banner ─────────────────────────────────────────────────────────
FAKE_BIN="$WORK_DIR/fakebin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/tachyon-core" <<'FAKE'
#!/bin/sh
echo "tachyon-core 0.5.7"
FAKE
chmod +x "$FAKE_BIN/tachyon-core"

with_fake_core() {
    PATH="$FAKE_BIN:$PATH" "$@"
}

got="$(with_fake_core ucode -L "$LIB_DIR" "$RT" core-profile "")"
[ "$got" = "tachyon-core" ] \
    || fail "a live 'tachyon-core 0.5.7' banner must resolve to tachyon-core, got '$got'"
ok

got="$(with_fake_core ucode -L "$LIB_DIR" "$RT" core-pin-field "")"
[ "$got" = "certificate_sha256" ] \
    || fail "tachyon-core accepts certificate_sha256, got '$got'"
ok
rm -rf "$FAKE_BIN"

# ─── the TLS pin field ───────────────────────────────────────────────────────
check_pin() {
    version="$1"; marker="$2"; want="$3"
    got="$(rt core-pin-field "$version" "$marker" || true)"
    [ "$got" = "$want" ] || fail "core-pin-field $version/$marker is '$got', want '$want'"
    ok
}

check_pin "0.5.7" "" "certificate_sha256"
check_pin "0.0.1-tachyon.0" "" "certificate_sha256"

# ─── schema gates ────────────────────────────────────────────────────────────
check_gate() {
    version="$1"; gate="$2"; want="$3"
    if rt "core-$gate" "$version"; then got=yes; else got=no; fi
    [ "$got" = "$want" ] || fail "core-$gate $version is $got, want $want"
    ok
}

check_gate "0.5.7" "has-1-14" yes
check_gate "0.5.7" "has-1-15" yes
check_gate "0.0.1-tachyon.0" "has-1-14" yes
check_gate "0.0.1-tachyon.0" "has-1-15" yes

# ─── protocols supported by tachyon-core ─────────────────────────────────────
for proto in vless trojan hysteria2 shadowsocks awg fptn cloudflared openconnect bridge wdtt mieru; do
    rt core-supports-protocol "$proto" "0.5.7" "" \
        || fail "tachyon-core must support $proto"
    ok
done

# ─── the whole answer, in one object ─────────────────────────────────────────
caps="$(rt core-capabilities "0.5.7" "")"
case "$caps" in
    *'"profile": "tachyon-core"'*) ok ;;
    *) fail "capabilities did not report the tachyon-core profile: $caps" ;;
esac
case "$caps" in
    *'"cert_pin": true'*) ok ;;
    *) fail "capabilities did not report cert_pin for tachyon-core: $caps" ;;
esac
case "$caps" in
    *'"foreign_series": 1'*) ok ;;
    *) fail "capabilities must mark tachyon-core as foreign_series=1: $caps" ;;
esac

echo "ok - $pass_count checks passed"
