#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

CRYPT4="$ROOT_DIR/tachyon/files/usr/lib/subscription/crypt4.uc"
CACHE="$ROOT_DIR/tachyon/files/usr/lib/subscription/cache.uc"
RUNTIME="$ROOT_DIR/tachyon/files/usr/lib/diagnostics/runtime.uc"

ucode_run() {
  command ucode -L "$TACHYON_LIB" "$@"
}

# 1. CLI is-crypt4 tests
ucode_run "$CRYPT4" is-crypt4 "happ://crypt4/dGVzdA==" || fail "happ://crypt4 should be recognized"
ucode_run "$CRYPT4" is-crypt4 "crypt4/dGVzdA==" || fail "crypt4/ should be recognized"
if ucode_run "$CRYPT4" is-crypt4 "https://example.com/sub.txt" 2>/dev/null; then
  fail "https:// URL should not be recognized as crypt4"
fi

# 2. End-to-end Decryption tests (AES-256-CBC)
PLAINTEXT="vless://00000000-0000-4000-8000-000000000001@example.com:443?encryption=none&security=tls&sni=example.com#HappNode"
SECRET="my-custom-device-hwid"

# Deterministic test vector (or dynamically generated if openssl CLI is present)
B64_PAYLOAD="AAECAwQFBgcICQoLDA0OD0OMKcI1aFmugKQB4r4K4OSN6xxDU5FmUUFRentyDOXfswM3t0kyFovZ5yaTDJ1pva68axdwhD4QWAebC6Jnbv7X5xJKCGOAMMAQ3uRuJe+nXl0Az2QN+xgljgGeQaM8UHM1t3+tX4FlEWyuaaNZ4dZFwJUh0Nitkz26Mfa9//Hn"

if command -v openssl >/dev/null 2>&1; then
  KEY_HEX="$(printf '%s' "$SECRET" | sha256sum | awk '{print $1}')"
  IV_HEX="000102030405060708090a0b0c0d0e0f"
  printf '\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f' >"$WORK_DIR/iv.bin"
  printf '%s' "$PLAINTEXT" | openssl enc -aes-256-cbc -K "$KEY_HEX" -iv "$IV_HEX" >"$WORK_DIR/cipher.bin" 2>/dev/null || true
  if [ -s "$WORK_DIR/cipher.bin" ]; then
    cat "$WORK_DIR/iv.bin" "$WORK_DIR/cipher.bin" >"$WORK_DIR/payload.bin"
    B64_PAYLOAD="$(base64 <"$WORK_DIR/payload.bin" | tr -d '\r\n ')"
  fi
fi

CRYPT4_URL="happ://crypt4/${B64_PAYLOAD}"

# Decrypt using crypt4 CLI
DECRYPTED="$(ucode_run "$CRYPT4" decrypt "$CRYPT4_URL" "$SECRET")"
[ "$DECRYPTED" = "$PLAINTEXT" ] || fail "Decrypted plaintext mismatch: got '$DECRYPTED', expected '$PLAINTEXT'"

# 3. Default salt decryption ("HappDefaultSalt")
SALT_B64="AAECAwQFBgcICQoLDA0OD6K0gDGOn/K3and0NuhjH6rDKR/ov8Xn8ESMdCk4+0rUkXQVLyUBpJTUyCagj1wCUWkMyOczDnAbhwthZ6HsuitMrPx4PnOGQypFH9+MdCQhZ+5mIkkO4g8+S5p4LTTqzA3H6U2wT6s21QmtkYxCmI8+0flp6JHnnm3Lp6krqaWq"

if command -v openssl >/dev/null 2>&1; then
  SALT_HEX="$(printf '%s' "HappDefaultSalt" | sha256sum | awk '{print $1}')"
  IV_HEX="000102030405060708090a0b0c0d0e0f"
  printf '\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f' >"$WORK_DIR/iv.bin"
  printf '%s' "$PLAINTEXT" | openssl enc -aes-256-cbc -K "$SALT_HEX" -iv "$IV_HEX" >"$WORK_DIR/salt_cipher.bin" 2>/dev/null || true
  if [ -s "$WORK_DIR/salt_cipher.bin" ]; then
    cat "$WORK_DIR/iv.bin" "$WORK_DIR/salt_cipher.bin" >"$WORK_DIR/salt_payload.bin"
    SALT_B64="$(base64 <"$WORK_DIR/salt_payload.bin" | tr -d '\r\n ')"
  fi
fi

SALT_CRYPT4_URL="crypt4/${SALT_B64}"

SALT_DECRYPTED="$(ucode_run "$CRYPT4" decrypt "$SALT_CRYPT4_URL")"
[ "$SALT_DECRYPTED" = "$PLAINTEXT" ] || fail "Default salt decrypt mismatch: got '$SALT_DECRYPTED'"

# 4. Corrupted / invalid input tests
if ucode_run "$CRYPT4" decrypt "crypt4/invalid_base64_!@#$" 2>/dev/null; then
  fail "corrupted base64 should return failure"
fi

# 5. Parser integration
cat >"$WORK_DIR/test_parser.uc" <<'UCODE'
let parser = require("subscription.parser");

// URL source entry validation
let entry = parser.parse_subscription_source_entry("happ://crypt4/dGVzdA==");
if (!entry.valid)
    exit(1);

let entry2 = parser.parse_subscription_source_entry("crypt4/dGVzdA==");
if (!entry2.valid)
    exit(2);

exit(0);
UCODE
ucode_run "$WORK_DIR/test_parser.uc" || fail "parser source entry validation for crypt4 failed"

# 6. Normalize content validation with encrypted file
ENCRYPTED_FILE="$WORK_DIR/sub_encrypted.txt"
NORMALIZED_OUT="$WORK_DIR/normalized.json"
printf '%s' "$SALT_CRYPT4_URL" >"$ENCRYPTED_FILE"

cat >"$WORK_DIR/test_normalize.uc" <<'UCODE'
let parser = require("subscription.parser");
let enc_file = ARGV[0];
let out_file = ARGV[1];

let ok = parser.normalize_content_validated(enc_file, out_file);
if (!ok) exit(1);
UCODE
ucode_run "$WORK_DIR/test_normalize.uc" "$ENCRYPTED_FILE" "$NORMALIZED_OUT" || fail "normalize_content_validated failed on crypt4"

grep -Fq "example.com" "$NORMALIZED_OUT" || fail "normalized output missing expected server domain"
grep -Fq "HappNode" "$NORMALIZED_OUT" || fail "normalized output missing server tag"

# 7. Cache download_subscription with crypt4 URL
CACHE_OUT="$WORK_DIR/cache_sub.txt"
ucode_run "$CACHE" download-subscription "$CRYPT4_URL" "$CACHE_OUT" "" "" "" "$SECRET" || fail "download_subscription failed for crypt4 URL"
[ -s "$CACHE_OUT" ] || fail "download_subscription produced empty cache output"
grep -Fq "HappNode" "$CACHE_OUT" || fail "download_subscription did not properly decrypt content"

# 8. Dual HWID request headers check in cache.uc
grep -Fq '"X-HWID: " + hwid_val' "$CACHE" || fail "missing X-HWID header in cache.uc"
grep -Fq '"HWID: " + hwid_val' "$CACHE" || fail "missing HWID header in cache.uc"

# 9. Diagnostics symptom collapsing test
DOCTOR_OUT="$(ucode_run "$RUNTIME" ai-doctor 2>/dev/null)" || fail "ai-doctor failed to run"
echo "$DOCTOR_OUT" | grep -Fq '"success": true' || fail "ai-doctor report missing success flag"
echo "$DOCTOR_OUT" | grep -Fq '"model": "rule_engine_v2"' || fail "ai-doctor report missing rule_engine_v2 model"

# Verify symptom collapsing: when WAN or sing-box fails, downstream proxy updates are collapsed/suppressed
if echo "$DOCTOR_OUT" | grep -Fq '"update_subscriptions"'; then
  fail "update_subscriptions should be suppressed when WAN/core service is unreachable"
fi

printf 'All Happ Crypt4, HWID, and symptom collapsing checks passed!\n'
