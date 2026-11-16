#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# Canonical serialized secret for key 367a189aee18fa31c190054efd4a8e95 with
# faketls host google.com. tachyon-core takes the 32-hex key part directly.
CANONICAL='ee367a189aee18fa31c190054efd4a8e95676f6f676c652e636f6d'
CORE_KEY='367a189aee18fa31c190054efd4a8e95'

fixture_with_secret() {
  cat >"$WORK_DIR/mtproto_fixture.json" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1"
  },
  "server": [
    {
      ".name": "my_mtproto_server",
      ".type": "server",
      "enabled": "1",
      "protocol": "mtproto",
      "listen_port": "443",
      "mtproto_secret": "$1",
      "mtproto_faketls": "google.com"
    }
  ],
  "section": [
    {
      ".name": "default_direct",
      ".type": "section",
      "enabled": "1",
      "action": "bypass"
    }
  ]
}
JSON
}

generate() {
  mkdir -p "$WORK_DIR/out.section-cache"
  ucode -L "$TACHYON_LIB" "$TACHYON_LIB/tachyon_core/generator.uc" generate-config-fixture \
    "$WORK_DIR/mtproto_fixture.json" "$WORK_DIR/tachyon_core_mtproto.json" "127.0.0.1" 0 0
}

assert_canonical_user_password() {
  grep -q '"type": "mtproto"' "$WORK_DIR/tachyon_core_mtproto.json" ||
    fail "mtproto server must emit an mtproto inbound, never a shadowsocks fallback"
  grep -q '"secret": "'"$CORE_KEY"'"' "$WORK_DIR/tachyon_core_mtproto.json" ||
    fail "tachyon-core config must carry the 32-hex secret key"
  if grep -q '"method": "2022' "$WORK_DIR/tachyon_core_mtproto.json"; then
    fail "mtproto inbound must not carry a shadowsocks-2022 method"
  fi
}

# 1. Full ee-secret in hex passes through unchanged.
fixture_with_secret "$CANONICAL"
generate
assert_canonical_user_password

# 2. Bare 16-byte key in hex gets wrapped with the marker and faketls host.
fixture_with_secret '367a189aee18fa31c190054efd4a8e95'
generate
assert_canonical_user_password

# 3. Full secret in padded standard base64 is decoded and re-encoded as hex.
fixture_with_secret '7jZ6GJruGPoxwZAFTv1KjpVnb29nbGUuY29t'
generate
assert_canonical_user_password

# 4. Bare key in padded standard base64 gets wrapped.
fixture_with_secret 'NnoYmu4Y+jHBkAVO/UqOlQ=='
generate
assert_canonical_user_password

# 5. Full secret in raw url-safe base64 (as produced by mtg) is normalized.
fixture_with_secret '7jZ6GJruGPoxwZAFTv1KjpVnb29nbGUuY29t'
generate
assert_canonical_user_password

# 6. Url-safe alphabet (- and _ instead of + and /) is translated.
fixture_with_secret 'NnoYmu4Y-jHBkAVO_UqOlQ'
generate
assert_canonical_user_password

# 7. The validator accepts a canonical secret and rejects garbage with a
# clear message instead of a tachyon-core FATAL at start time.
cat >"$WORK_DIR/validate_secret.uc" <<'UC'
let common = require("core.common");
let secret = ARGV[1];
printf("%s", common.mtproto_secret_canonical(secret, "google.com") == null ? "invalid" : "valid");
UC

[ "$(ucode -L "$TACHYON_LIB" "$WORK_DIR/validate_secret.uc" x "$CANONICAL")" = "valid" ] ||
  fail "validator helper must accept the canonical hex secret"
[ "$(ucode -L "$TACHYON_LIB" "$WORK_DIR/validate_secret.uc" x '7jZ6GJruGPoxwZAFTv1KjpVnb29nbGUuY29t')" = "valid" ] ||
  fail "validator helper must accept the base64 form of the secret"
[ "$(ucode -L "$TACHYON_LIB" "$WORK_DIR/validate_secret.uc" x 'not a real secret')" = "invalid" ] ||
  fail "validator helper must reject unparseable secrets"
[ "$(ucode -L "$TACHYON_LIB" "$WORK_DIR/validate_secret.uc" x '')" = "invalid" ] ||
  fail "validator helper must reject an empty secret"

printf 'MTProto server configuration checks passed\n'
