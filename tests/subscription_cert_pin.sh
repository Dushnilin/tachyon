#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

set -eo pipefail

ucode() {
  command ucode -L "$TACHYON_LIB" "$@"
}

PARSER="$ROOT_DIR/tachyon/files/usr/lib/subscription/parser.uc"

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

# The OpenSSL shape: hex byte pairs joined by colons. This is what providers
# actually send, percent-encoded inside links, and rejecting it dropped the pin
# silently - the node then fails CA or name validation with nothing in the log.
COLON_HEX="$(printf '%s' "$HEX" | sed 's/../&:/g; s/:$//')"
COLON_QUERY="$(printf '%s' "$COLON_HEX" | sed 's/:/%3A/g')"

ucode -e '
let common = require("core.common");
if (common.certificate_pin_base64(ARGV[0]) !== ARGV[1]) exit(1);
if (common.certificate_pin_base64(ARGV[2]) !== ARGV[1]) exit(2);
if (common.certificate_pin_base64(ARGV[3]) !== "") exit(3);
if (common.certificate_pin_base64(ARGV[4]) !== "") exit(4);
if (common.certificate_pin_base64("") !== "") exit(5);
if (common.certificate_pin_base64(ARGV[5]) !== ARGV[1]) exit(6);
if (common.certificate_pin_base64(ARGV[6]) !== ARGV[1]) exit(7);
if (common.certificate_pin_base64(" " + ARGV[5] + " ") !== ARGV[1]) exit(8);
// Several fingerprints in one field, comma or space separated: the first is the pin.
if (common.certificate_pin_base64(ARGV[5] + "," + ARGV[0]) !== ARGV[1]) exit(9);
if (common.certificate_pin_base64(ARGV[5] + " " + ARGV[0]) !== ARGV[1]) exit(11);
// A colon-separated value of the wrong length is still refused.
if (common.certificate_pin_base64("28:6A:02:8E") !== "") exit(10);
' "$HEX" "$B64" "$(printf '%s' "$HEX" | tr 'a-f' 'A-F')" "$BAD64" "$BAD63" \
  "$COLON_HEX" "$(printf '%s' "$COLON_HEX" | tr 'a-f' 'A-F')" ||
  fail "common.certificate_pin_base64 contract"

vless_colon_output="$(normalize_link "vless-pinned-colons" "vless://$UUID@example.com:443?encryption=none&security=tls&fp=chrome&sni=example.com&pcs=$COLON_QUERY#vless-pinned-colons")"
assert_contains "$vless_colon_output" "$EXPECTED_FIELD" "vless-pinned-colons"

# Xray-JSON spelling. auto_user_agent is on by default, so a provider answers with
# Xray-JSON instead of a link list, and the pin was simply not read at all.
normalize_xray() { # <label> <json> -> normalized output path
  local label="$1" json="$2"
  printf '%s\n' "$json" >"$WORK_DIR/$label.in.json"
  ucode "$PARSER" normalize-content "$WORK_DIR/$label.in.json" "$WORK_DIR/$label.out.json" ||
    fail "normalize-content failed for $label"
  printf '%s\n' "$WORK_DIR/$label.out.json"
}

xray_output="$(normalize_xray "xray-pin" "{\"outbounds\":[{\"protocol\":\"vless\",\"tag\":\"xray-pinned\",\"settings\":{\"vnext\":[{\"address\":\"example.com\",\"port\":443,\"users\":[{\"id\":\"$UUID\"}]}]},\"streamSettings\":{\"network\":\"tcp\",\"security\":\"tls\",\"tlsSettings\":{\"serverName\":\"example.com\",\"fingerprint\":\"chrome\",\"pinnedPeerCertSha256\":\"$COLON_HEX\"}}}]}")"
assert_contains "$xray_output" "$EXPECTED_FIELD" "xray-json pinnedPeerCertSha256"

xray_plain_output="$(normalize_xray "xray-no-pin" "{\"outbounds\":[{\"protocol\":\"vless\",\"tag\":\"xray-plain\",\"settings\":{\"vnext\":[{\"address\":\"example.com\",\"port\":443,\"users\":[{\"id\":\"$UUID\"}]}]},\"streamSettings\":{\"network\":\"tcp\",\"security\":\"tls\",\"tlsSettings\":{\"serverName\":\"example.com\"}}}]}")"
assert_not_contains "$xray_plain_output" "certificate_sha256" "xray-json without a pin"

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

# tachyon-core pins via certificate_sha256.
TACHYON_CORE_VERSION_OVERRIDE="0.5.7" ucode -e '
let generator = require("tachyon_core.generator_outbounds");
let outbound = generator.manual_vless_outbound(ARGV[0], "pin-test");
if (type(outbound.tls) != "object") exit(1);
if (type(outbound.tls.certificate_sha256) != "array") exit(2);
if (outbound.tls.certificate_sha256[0] !== ARGV[1]) exit(3);
if (type(outbound.tls.certificate_public_key_sha256) == "array") exit(4);
' "$vless_link" "$B64" \
  || fail "manual vless link must pin via certificate_sha256 on tachyon-core"

# 6. Verify tachyon_core/runtime.uc and generator.uc agree on supports-cert-pin
for version in 0.4.8 0.5.7 v0.0.1-tachyon.0; do
  ucode "$ROOT_DIR/tachyon/files/usr/lib/tachyon_core/runtime.uc" supports-cert-pin "$version" ||
    fail "supports-cert-pin must succeed on tachyon-core $version"
  ucode "$ROOT_DIR/tachyon/files/usr/lib/tachyon_core/generator.uc" is-cert-pin-supported "$version" ||
    fail "generator is-cert-pin-supported must succeed on tachyon-core $version"
done

TEST_CFG='{"outbounds":[{"type":"vless","tag":"pinned-node","tls":{"enabled":true,"server_name":"example.com","certificate_sha256":["abc"]}}]}'
printf '0.5.7\n' > "$WORK_DIR/ver_core"
kept="$(printf '%s' "$TEST_CFG" | TACHYON_CORE_VERSION_FILE="$WORK_DIR/ver_core" ucode "$ROOT_DIR/tachyon/files/usr/lib/tachyon_core/generator.uc" strip-cert-pins 2>/dev/null)"
if ! grep -Fq "certificate_sha256" <<<"$kept"; then
  fail "generator must keep certificate_sha256 on tachyon-core"
fi

# 7. Verify diagnostics reports tachyon_core_cert_pin capability flag
server_caps="$(ucode "$ROOT_DIR/tachyon/files/usr/lib/diagnostics/runtime.uc" get-server-capabilities)"
printf '%s\n' "$server_caps" > "$WORK_DIR/caps.json"
assert_contains "$WORK_DIR/caps.json" "tachyon_core_cert_pin" "capabilities-has-cert-pin"

core_chk="$(ucode "$ROOT_DIR/tachyon/files/usr/lib/diagnostics/runtime.uc" check-tachyon-core)"
printf '%s\n' "$core_chk" > "$WORK_DIR/core_chk.json"
assert_contains "$WORK_DIR/core_chk.json" "tachyon_core_cert_pin" "check-tachyon-core-has-cert-pin"

printf 'subscription certificate pin checks passed\n'
