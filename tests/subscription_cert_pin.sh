#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARSER="$ROOT_DIR/tachyon/files/usr/lib/subscription/parser.uc"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

ucode() {
  command ucode -L "$TACHYON_LIB" "$@"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  local label="$3"

  if ! grep -Fq -- "$expected" "$file"; then
    printf 'Output for %s:\n' "$label" >&2
    cat "$file" >&2
    fail "$label: expected to find $expected"
  fi
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  local label="$3"

  if grep -Fq -- "$unexpected" "$file"; then
    printf 'Output for %s:\n' "$label" >&2
    cat "$file" >&2
    fail "$label: did not expect to find $unexpected"
  fi
}

normalize_link() {
  local label="$1"
  local link="$2"
  local input="$WORK_DIR/$label.in"
  local output="$WORK_DIR/$label.json"

  printf '%s\n' "$link" > "$input"
  ucode "$PARSER" normalize-uri-list "$input" "$output"
  printf '%s\n' "$output"
}

UUID='00000000-0000-4000-8000-000000000001'
HEX='9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08'
B64='n4bQgYhMfWWaL+qgxVrQFaO/TxsrC4Is0V1sFbDwCgg='
BAD64="$(printf 'g%.0s' {1..64})"
BAD63="${HEX:0:63}"
EXPECTED_FIELD="\"certificate_sha256\": [ \"$B64\" ]"

ucode -e '
let common = require("core.common");
if (common.certificate_pin_base64(ARGV[0]) !== ARGV[1]) exit(1);
if (common.certificate_pin_base64(ARGV[2]) !== ARGV[1]) exit(2);
if (common.certificate_pin_base64(ARGV[3]) !== "") exit(3);
if (common.certificate_pin_base64(ARGV[4]) !== "") exit(4);
if (common.certificate_pin_base64("") !== "") exit(5);
' "$HEX" "$B64" "$(printf '%s' "$HEX" | tr 'a-f' 'A-F')" "$BAD64" "$BAD63" ||
  fail "common.certificate_pin_base64 contract"

vless_output="$(normalize_link "vless-pinned" "vless://$UUID@example.com:443?encryption=none&security=tls&fp=chrome&sni=example.com&pcs=$HEX#vless-pinned")"
assert_contains "$vless_output" "$EXPECTED_FIELD" "vless-pinned"

vless_upper_output="$(normalize_link "vless-pinned-upper" "vless://$UUID@example.com:443?encryption=none&security=tls&fp=chrome&sni=example.com&pcs=$(printf '%s' "$HEX" | tr 'a-f' 'A-F')#vless-pinned-upper")"
assert_contains "$vless_upper_output" "$EXPECTED_FIELD" "vless-pinned-upper"

vless_clean_output="$(normalize_link "vless-clean" "vless://$UUID@example.com:443?encryption=none&security=tls&fp=chrome&sni=example.com#vless-clean")"
assert_not_contains "$vless_clean_output" "certificate_sha256" "vless-clean"

vless_bad_output="$(normalize_link "vless-pinned-bad" "vless://$UUID@example.com:443?encryption=none&security=tls&fp=chrome&sni=example.com&pcs=$BAD64#vless-pinned-bad")"
assert_not_contains "$vless_bad_output" "certificate_sha256" "vless-pinned-bad"

vless_bad_len_output="$(normalize_link "vless-pinned-bad-len" "vless://$UUID@example.com:443?encryption=none&security=tls&fp=chrome&sni=example.com&pcs=$BAD63#vless-pinned-bad-len")"
assert_not_contains "$vless_bad_len_output" "certificate_sha256" "vless-pinned-bad-len"

trojan_output="$(normalize_link "trojan-pinned" "trojan://secret@example.com:443?security=tls&fp=chrome&sni=example.com&pcs=$HEX#trojan-pinned")"
assert_contains "$trojan_output" "$EXPECTED_FIELD" "trojan-pinned"

hy2_output="$(normalize_link "hy2-pinned" "hysteria2://secret@example.com:443?sni=example.com&pcs=$HEX#hy2-pinned")"
assert_contains "$hy2_output" "$EXPECTED_FIELD" "hy2-pinned"

tuic_output="$(normalize_link "tuic-pinned" "tuic://$UUID:secret@example.com:443?sni=example.com&pcs=$HEX#tuic-pinned")"
assert_contains "$tuic_output" "$EXPECTED_FIELD" "tuic-pinned"

http_output="$(normalize_link "https-pinned" "https://example.com:443?sni=example.com&pcs=$HEX#https-pinned")"
assert_contains "$http_output" "$EXPECTED_FIELD" "https-pinned"

cat >"$WORK_DIR/pinned.json" <<JSON
{"outbounds":[{"type":"vless","tag":"pinned","server":"example.com","server_port":443,"uuid":"$UUID","tls":{"enabled":true,"server_name":"example.com","certificate_sha256":["$B64"]}}]}
JSON
ucode "$PARSER" validate-subscription "$WORK_DIR/pinned.json" ||
  fail "subscription with certificate_sha256 must pass validation"

vless_link="vless://$UUID@example.com:443?encryption=none&security=tls&fp=chrome&sni=example.com&pcs=$HEX#vless-pinned"
ucode -e '
let share = require("subscription.share_link");
let link = share.serialize_outbound_link({
    type: "vless",
    server: "example.com",
    server_port: 443,
    uuid: ARGV[0],
    tls: { enabled: true, server_name: "example.com", certificate_sha256: [ ARGV[1] ] }
});
if (index(link, "pcs=" + ARGV[2]) < 0) {
    print(link + "\n");
    exit(1);
}
' "$UUID" "$B64" "$HEX" || fail "share_link vless pcs round-trip"

ucode -e '
let share = require("subscription.share_link");
let link = share.serialize_outbound_link({
    type: "hysteria2",
    server: "example.com",
    server_port: 443,
    password: "secret",
    tls: { enabled: true, server_name: "example.com", certificate_sha256: [ ARGV[0] ] }
});
if (index(link, "pcs=" + ARGV[1]) < 0) {
    print(link + "\n");
    exit(1);
}
' "$B64" "$HEX" || fail "share_link hysteria2 pcs round-trip"

ucode -e '
let generator = require("singbox.generator_outbounds");
let outbound = generator.manual_vless_outbound(ARGV[0], "pin-test");
if (type(outbound.tls) != "object") exit(1);
if (type(outbound.tls.certificate_sha256) != "array") exit(2);
if (outbound.tls.certificate_sha256[0] !== ARGV[1]) exit(3);
' "$vless_link" "$B64" || fail "manual vless link applies certificate pin"

# 6. Verify singbox/runtime.uc supports-cert-pin version gates
ucode "$ROOT_DIR/tachyon/files/usr/lib/singbox/runtime.uc" supports-cert-pin "1.15.0" ||
  fail "supports-cert-pin must succeed on 1.15.0"
ucode "$ROOT_DIR/tachyon/files/usr/lib/singbox/runtime.uc" supports-cert-pin "1.15.2" ||
  fail "supports-cert-pin must succeed on 1.15.2"
ucode "$ROOT_DIR/tachyon/files/usr/lib/singbox/runtime.uc" supports-cert-pin "v1.16.1" ||
  fail "supports-cert-pin must succeed on v1.16.1"
# These lx versions are all below 1.15, which is the only reason the pin field is
# missing - not anything about lx. Checked against the real 1.14.2-lx.8 binary:
# it rejects certificate_sha256 with "unknown field" exactly as stock 1.14.2 does.
if ucode "$ROOT_DIR/tachyon/files/usr/lib/singbox/runtime.uc" supports-cert-pin "1.14.2-lx.4"; then
  fail "supports-cert-pin must fail on 1.14.2-lx.4 (predates the 1.15.0 field)"
fi
if ucode "$ROOT_DIR/tachyon/files/usr/lib/singbox/runtime.uc" supports-cert-pin "1.14.0-lx.32"; then
  fail "supports-cert-pin must fail on 1.14.0-lx.32 (predates the 1.15.0 field)"
fi
if ucode "$ROOT_DIR/tachyon/files/usr/lib/singbox/runtime.uc" supports-cert-pin "sing-box-lx"; then
  fail "supports-cert-pin must fail on a bare variant name with no version to judge"
fi

# The variant marker must NOT decide this. lx on 1.14.2 is unsupported because
# of its version, same as stock, and lx on 1.15 is supported, same as stock. A
# build-level exclusion would strip pins from every future lx release.
printf 'lx\n' > "$WORK_DIR/variant_lx"
if SB_VARIANT_STATE_FILE="$WORK_DIR/variant_lx" \
  ucode "$ROOT_DIR/tachyon/files/usr/lib/singbox/runtime.uc" supports-cert-pin "1.15.0"; then :; else
  fail "supports-cert-pin must succeed on 1.15.0 even when the variant marker says lx - the field is gated by version, not by build (issue #79)"
fi

if ucode "$ROOT_DIR/tachyon/files/usr/lib/singbox/runtime.uc" supports-cert-pin "1.13.0"; then
  fail "supports-cert-pin must fail on 1.13.0"
fi
if ucode "$ROOT_DIR/tachyon/files/usr/lib/singbox/runtime.uc" supports-cert-pin "1.14.9"; then
  fail "supports-cert-pin must fail on 1.14.9"
fi

# 7. Generator: pins are kept only where the field exists (issue #79)
GENERATOR_UC="$ROOT_DIR/tachyon/files/usr/lib/singbox/generator.uc"

if ucode "$GENERATOR_UC" is-cert-pin-supported "1.14.2-lx.4"; then
  fail "generator is-cert-pin-supported must fail on 1.14.2-lx.4 (lx has no certificate_sha256)"
fi
ucode "$GENERATOR_UC" is-cert-pin-supported "1.15.0" ||
  fail "generator is-cert-pin-supported must succeed on 1.15.0"
if ucode "$GENERATOR_UC" is-cert-pin-supported "1.14.2"; then
  fail "generator is-cert-pin-supported must fail on stock 1.14.2"
fi

TEST_CFG='{"outbounds":[{"type":"vless","tag":"pinned-node","tls":{"enabled":true,"server_name":"example.com","certificate_sha256":["abc"]}}]}'

printf '1.14.2-lx.4\n' > "$WORK_DIR/ver_lx"
lx_stripped="$(printf '%s' "$TEST_CFG" | SB_VERSION_STATE_FILE="$WORK_DIR/ver_lx" ucode "$GENERATOR_UC" strip-cert-pins 2>/dev/null)"
if grep -Fq "certificate_sha256" <<<"$lx_stripped"; then
  fail "generator must strip certificate_sha256 for sing-box-lx (the field does not exist there)"
fi

printf '1.14.2\n' > "$WORK_DIR/ver_stock"
stock_stripped="$(printf '%s' "$TEST_CFG" | SB_VERSION_STATE_FILE="$WORK_DIR/ver_stock" ucode "$GENERATOR_UC" strip-cert-pins 2>/dev/null)"
if grep -Fq "certificate_sha256" <<<"$stock_stripped"; then
  fail "generator must strip certificate_sha256 for stock sing-box 1.14.2"
fi

printf '1.15.0\n' > "$WORK_DIR/ver_new"
new_stripped="$(printf '%s' "$TEST_CFG" | SB_VERSION_STATE_FILE="$WORK_DIR/ver_new" ucode "$GENERATOR_UC" strip-cert-pins 2>/dev/null)"
if ! grep -Fq "certificate_sha256" <<<"$new_stripped"; then
  fail "generator must keep certificate_sha256 on sing-box 1.15+"
fi

# 7b. The field is gated by version, not by build.
#
# This started as a claim that sing-box-lx is a special case. It is not, and
# checking the real binaries settles it: stock 1.14.2 and 1.14.2-lx.8 both
# reject tls.certificate_sha256 with "unknown field", and both accept
# certificate_public_key_sha256. The official docs say certificate_sha256 was
# added upstream in 1.15.0 and is the SHA-256 of the whole DER certificate,
# while certificate_public_key_sha256 (1.13.0) hashes the public key - a
# different value, so it cannot stand in for a pcs.
#
# sing-box-lx tracks upstream, so excluding it by name would have cost it the
# feature for good once it passed 1.15. The rule is the version, so that is what
# is pinned here: the two must agree, and neither may special-case lx.
printf '%-16s %-11s %-11s\n' variant generator runtime
for variant in 1.15.0 1.15.2 v1.16.1 1.14.2 1.14.2-lx.8 1.14.0-lx.32 1.15.0-lx.1 1.16.0-lx.3; do
  if ucode "$GENERATOR_UC" is-cert-pin-supported "$variant" 2>/dev/null; then gen=supported; else gen=unsupported; fi
  if ucode "$ROOT_DIR/tachyon/files/usr/lib/singbox/runtime.uc" supports-cert-pin "$variant" 2>/dev/null; then rt=supported; else rt=unsupported; fi
  printf '%-16s %-11s %-11s\n' "$variant" "$gen" "$rt"
  [ "$gen" = "$rt" ] ||
    fail "generator and runtime disagree about $variant: generator=$gen runtime=$rt - the generator would emit a field the runtime then strips (issue #79)"
done

# lx must be judged by its version like anything else. A build-level exclusion
# would strip pins from an lx that has the field, which is exactly the state lx
# will be in once it tracks upstream past 1.15.
if ! ucode "$GENERATOR_UC" is-cert-pin-supported "1.15.0-lx.1" 2>/dev/null; then
  fail "generator excludes sing-box-lx 1.15 by build name - certificate_sha256 is an upstream 1.15.0 field and lx tracks upstream, so that would strip pins from an lx that has the field"
fi
if ! ucode "$ROOT_DIR/tachyon/files/usr/lib/singbox/runtime.uc" supports-cert-pin "1.15.0-lx.1" 2>/dev/null; then
  fail "runtime excludes sing-box-lx 1.15 by build name - same reason"
fi

# And below 1.15 the pin is dropped, on lx exactly as on stock, because there is
# no field to put it in anywhere.
printf '1.15.0-lx.1\n' > "$WORK_DIR/ver_lx_new"
lx_new_stripped="$(printf '%s' "$TEST_CFG" | SB_VERSION_STATE_FILE="$WORK_DIR/ver_lx_new" ucode "$GENERATOR_UC" strip-cert-pins 2>/dev/null)"
if ! grep -Fq "certificate_sha256" <<<"$lx_new_stripped"; then
  fail "generator must keep certificate_sha256 on sing-box-lx 1.15 - the field is an upstream 1.15.0 field and lx tracks upstream"
fi
printf '1.14.2-lx.8\n' > "$WORK_DIR/ver_lx_old"
lx_old_stripped="$(printf '%s' "$TEST_CFG" | SB_VERSION_STATE_FILE="$WORK_DIR/ver_lx_old" ucode "$GENERATOR_UC" strip-cert-pins 2>/dev/null)"
if grep -Fq "certificate_sha256" <<<"$lx_old_stripped"; then
  fail "generator must strip certificate_sha256 below 1.15 on any build, lx included"
fi

# 8. Verify diagnostics reports sing_box_cert_pin capability flag
server_caps="$(ucode "$ROOT_DIR/tachyon/files/usr/lib/diagnostics/runtime.uc" get-server-capabilities)"
printf '%s\n' "$server_caps" > "$WORK_DIR/caps.json"
assert_contains "$WORK_DIR/caps.json" "sing_box_cert_pin" "capabilities-has-cert-pin"

singbox_chk="$(ucode "$ROOT_DIR/tachyon/files/usr/lib/diagnostics/runtime.uc" check-sing-box)"
printf '%s\n' "$singbox_chk" > "$WORK_DIR/sb_chk.json"
assert_contains "$WORK_DIR/sb_chk.json" "sing_box_cert_pin" "check-sing-box-has-cert-pin"

printf 'subscription certificate pin checks passed\n'
