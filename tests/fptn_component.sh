#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UPDATES_UC="$ROOT_DIR/tachyon/files/usr/lib/components/updates.uc"
ACTION_UC="$ROOT_DIR/tachyon/files/usr/lib/components/action.uc"
PACKAGES_UC="$ROOT_DIR/tachyon/files/usr/lib/core/packages.uc"
STATE_UC="$ROOT_DIR/tachyon/files/usr/lib/service/state.uc"
SNAPSHOT_UC="$ROOT_DIR/tachyon/files/usr/lib/service/snapshot.uc"
SYSTEM_INFO_UC="$ROOT_DIR/tachyon/files/usr/lib/diagnostics/system_info.uc"
TACHYON_BIN="$ROOT_DIR/tachyon/files/usr/bin/tachyon"
TACHYON_READ_BIN="$ROOT_DIR/tachyon/files/usr/bin/tachyon-read"

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

ucode_run() {
  ucode -L "$TACHYON_LIB" "$@"
}

# 1. Verify standalone FPTN package component is rejected by component manager & absent from CLI
if grep -Fq 'get_fptn_status' "$TACHYON_BIN" "$TACHYON_READ_BIN"; then
  fail "get_fptn_status must be removed from /usr/bin/tachyon and /usr/bin/tachyon-read"
fi
if grep -Fq 'fptn-client' "$PACKAGES_UC" "$ACTION_UC"; then
  fail "fptn-client package handling must be removed from packages.uc and components/action.uc"
fi
if grep -Fq '"fptn"' "$UPDATES_UC" "$SNAPSHOT_UC"; then
  fail "fptn component must be removed from components/updates.uc and service/snapshot.uc"
fi
if grep -Fq 'fptn_installed' "$SYSTEM_INFO_UC"; then
  fail "fptn_installed component field must be removed from diagnostics/system_info.uc"
fi
grep -Fq 'sing_box_fptn' "$SYSTEM_INFO_UC" ||
  fail "native sing_box_fptn core capability flag must remain in diagnostics/system_info.uc"

# 2. Verify state.uc sing-box-signature-fixture changes when FPTN section options change
cat >"$WORK_DIR/state_fixture.json" <<'EOF_FIXTURE'
{
  "section": [
    {
      ".name": "sec1",
      "enabled": "1",
      "action": "fptn",
      "access_token": "secret_token_123",
      "sni": "my.domain.com",
      "bypass_method": "obfuscation",
      "preferred_server": "198.51.100.10"
    }
  ]
}
EOF_FIXTURE

SIG_1="$(ucode_run "$STATE_UC" sing-box-signature-fixture "$WORK_DIR/state_fixture.json")"
[ -n "$SIG_1" ] || fail "sing-box signature should not be empty"

cat >"$WORK_DIR/state_fixture2.json" <<'EOF_FIXTURE2'
{
  "section": [
    {
      ".name": "sec1",
      "enabled": "1",
      "action": "fptn",
      "access_token": "secret_token_diff",
      "sni": "my.domain.com",
      "bypass_method": "obfuscation",
      "preferred_server": "198.51.100.10"
    }
  ]
}
EOF_FIXTURE2

SIG_2="$(ucode_run "$STATE_UC" sing-box-signature-fixture "$WORK_DIR/state_fixture2.json")"
[ "$SIG_1" != "$SIG_2" ] || fail "sing-box signature must differ when FPTN token changes"

cat >"$WORK_DIR/state_fixture3.json" <<'EOF_FIXTURE3'
{
  "section": [
    {
      ".name": "sec1",
      "enabled": "1",
      "action": "fptn",
      "access_token": "secret_token_123",
      "sni": "alt.domain.com",
      "bypass_method": "reality",
      "preferred_server": "203.0.113.20"
    }
  ]
}
EOF_FIXTURE3

SIG_3="$(ucode_run "$STATE_UC" sing-box-signature-fixture "$WORK_DIR/state_fixture3.json")"
[ "$SIG_1" != "$SIG_3" ] || fail "sing-box signature must differ when FPTN sni/bypass_method/preferred_server change"

# 3. Verify validator supports native fptn rule action without external binary
cat >"$WORK_DIR/fptn_valid.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "main_action": "direct",
    "dns_server": ["77.88.8.8"],
    "bootstrap_dns_server": ["77.88.8.8"]
  },
  "sec_fptn": {
    ".name": "sec_fptn",
    ".type": "section",
    "enabled": "1",
    "action": "fptn",
    "access_token": "secret_token_123"
  }
}
JSON
TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$ROOT_DIR/tachyon/files/usr/lib/config/validator.uc" validate-runtime-fixture "$WORK_DIR/fptn_valid.json" "{}" || fail "validator rejected valid fptn config"

# 4. Verify telegram token masking subcommand
TG_MASK_OUT="$(ucode -L "$TACHYON_LIB" "$ROOT_DIR/tachyon/files/usr/lib/service/telegram.uc" mask-token "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9Q7Fx")"
assert_eq "••••••••Q7Fx" "$TG_MASK_OUT" "telegram token masking"

echo "fptn native protocol & component removal tests passed"

