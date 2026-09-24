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

if ucode "$ROOT_DIR/tachyon/files/usr/lib/singbox/runtime.uc" supports-cert-pin "1.13.0"; then
  fail "supports-cert-pin must fail on 1.13.0"
fi
if ucode "$ROOT_DIR/tachyon/files/usr/lib/singbox/runtime.uc" supports-cert-pin "1.14.9"; then
  fail "supports-cert-pin must fail on 1.14.9"
fi

# 7. Verify diagnostics reports sing_box_cert_pin capability flag
server_caps="$(ucode "$ROOT_DIR/tachyon/files/usr/lib/diagnostics/runtime.uc" get-server-capabilities)"
printf '%s\n' "$server_caps" > "$WORK_DIR/caps.json"
assert_contains "$WORK_DIR/caps.json" "sing_box_cert_pin" "capabilities-has-cert-pin"

singbox_chk="$(ucode "$ROOT_DIR/tachyon/files/usr/lib/diagnostics/runtime.uc" check-sing-box)"
printf '%s\n' "$singbox_chk" > "$WORK_DIR/sb_chk.json"
assert_contains "$WORK_DIR/sb_chk.json" "sing_box_cert_pin" "check-sing-box-has-cert-pin"

printf 'subscription certificate pin checks passed\n'
