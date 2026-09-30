#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UPDATER_UC="$ROOT_DIR/tachyon/files/usr/lib/components/updater.uc"
PACKAGES_UC="$ROOT_DIR/tachyon/files/usr/lib/core/packages.uc"
FPTN_RUNTIME_UC="$ROOT_DIR/tachyon/files/usr/lib/providers/fptn/runtime.uc"
STATE_UC="$ROOT_DIR/tachyon/files/usr/lib/service/state.uc"
DIAGNOSTICS_UC="$ROOT_DIR/tachyon/files/usr/lib/diagnostics/runtime.uc"

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

ucode_run() {
  ucode -L "$TACHYON_LIB" "$@"
}

# 1. Test updater.uc asset selection for FPTN
cat >"$WORK_DIR/releases.json" <<'EOF_JSON'
[
  {
    "tag_name": "v0.4.5",
    "name": "0.4.5",
    "html_url": "https://github.com/fptn-project/fptn/releases/tag/v0.4.5",
    "assets": [
      {
        "name": "fptn-client-0.4.5-openwrt-23.05.x-x86_64.ipk",
        "browser_download_url": "https://github.com/fptn-project/fptn/releases/download/v0.4.5/fptn-client-0.4.5-openwrt-23.05.x-x86_64.ipk"
      },
      {
        "name": "fptn-client-0.4.5-openwrt-24.10.x-x86_64.apk",
        "browser_download_url": "https://github.com/fptn-project/fptn/releases/download/v0.4.5/fptn-client-0.4.5-openwrt-24.10.x-x86_64.apk"
      },
      {
        "name": "fptn-client-0.4.5-openwrt-24.10.x-aarch64_cortex-a53.apk",
        "browser_download_url": "https://github.com/fptn-project/fptn/releases/download/v0.4.5/fptn-client-0.4.5-openwrt-24.10.x-aarch64_cortex-a53.apk"
      }
    ]
  }
]
EOF_JSON

SELECTED_APK="$(cat "$WORK_DIR/releases.json" | ucode_run "$UPDATER_UC" fptn-select-asset "24.10" "apk" "aarch64_cortex-a53 aarch64_generic")"
ARCH_MATCH="$(echo "$SELECTED_APK" | awk '{print $1}')"
NAME_MATCH="$(echo "$SELECTED_APK" | awk '{print $2}')"
assert_eq "aarch64_cortex-a53" "$ARCH_MATCH" "fptn asset arch match"
assert_eq "fptn-client-0.4.5-openwrt-24.10.x-aarch64_cortex-a53.apk" "$NAME_MATCH" "fptn asset name match"

# 2. Test package version extraction
PARSED_VER="$(ucode_run "$UPDATER_UC" updates-arch-package-version "fptn-client-0.4.5-openwrt-24.10.x-x86_64.ipk" "x86_64")"
assert_eq "0.4.5-openwrt-24.10.x" "$PARSED_VER" "fptn package version strip"

# 3. Test packages.uc binary detection and version
MOCK_BIN="$WORK_DIR/fptn-client-cli"
cat >"$MOCK_BIN" <<'EOF_BIN'
#!/usr/bin/env sh
echo "fptn-client 0.4.5"
EOF_BIN
chmod 0755 "$MOCK_BIN"

export TACHYON_FPTN_BIN="$MOCK_BIN"
FPTN_VER="$(TACHYON_LIB_DIR="$TACHYON_LIB" ucode_run "$FPTN_RUNTIME_UC" version)"
assert_eq "0.4.5" "$FPTN_VER" "fptn runtime version command"

FPTN_INSTALLED="$(TACHYON_LIB_DIR="$TACHYON_LIB" ucode_run "$FPTN_RUNTIME_UC" installed && echo "1" || echo "0")"
assert_eq "1" "$FPTN_INSTALLED" "fptn runtime installed check"

# 4. Test state.uc fptn runtime signature fixture
cat >"$WORK_DIR/state_fixture.json" <<'EOF_FIXTURE'
{
  "section": [
    {
      ".name": "sec1",
      "enabled": "1",
      "action": "fptn",
      "access_token": "secret_token_123",
      "sni": "my.domain.com"
    }
  ]
}
EOF_FIXTURE

SIG_1="$(ucode_run "$STATE_UC" fptn-runtime-signature-fixture "$WORK_DIR/state_fixture.json")"
[ -n "$SIG_1" ] || fail "fptn signature should not be empty"

cat >"$WORK_DIR/state_fixture2.json" <<'EOF_FIXTURE2'
{
  "section": [
    {
      ".name": "sec1",
      "enabled": "1",
      "action": "fptn",
      "access_token": "secret_token_diff",
      "sni": "my.domain.com"
    }
  ]
}
EOF_FIXTURE2

SIG_2="$(ucode_run "$STATE_UC" fptn-runtime-signature-fixture "$WORK_DIR/state_fixture2.json")"
[ "$SIG_1" != "$SIG_2" ] || fail "fptn signature should differ when token changes"

# 5. Test diagnostics runtime dispatch for get-fptn-status
STATUS_OUT="$(TACHYON_LIB="$TACHYON_LIB" ucode_run "$DIAGNOSTICS_UC" get-fptn-status)"
echo "$STATUS_OUT" | grep -q '"ready":' || fail "get-fptn-status should return status json"
echo "$STATUS_OUT" | grep -q '"process_running":' || fail "get-fptn-status should include process_running"
echo "$STATUS_OUT" | grep -q '"tun_up":' || fail "get-fptn-status should include tun_up"
echo "$STATUS_OUT" | grep -q '"route_installed":' || fail "get-fptn-status should include route_installed"
echo "$STATUS_OUT" | grep -q '"rule_installed":' || fail "get-fptn-status should include rule_installed"
echo "$STATUS_OUT" | grep -q '"status_message":' || fail "get-fptn-status should include status_message"

# 6. Test fptn ensure-routing command syntax
ENSURE_RES="$(TACHYON_LIB_DIR="$TACHYON_LIB" ucode_run "$FPTN_RUNTIME_UC" ensure-routing && echo "1" || echo "0")"
assert_eq "1" "$ENSURE_RES" "ensure-routing should execute successfully"

# 7. Test validator supports fptn rule action
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

# 8. Test telegram token masking subcommand
TG_MASK_OUT="$(ucode -L "$TACHYON_LIB" "$ROOT_DIR/tachyon/files/usr/lib/service/telegram.uc" mask-token "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9Q7Fx")"
assert_eq "••••••••Q7Fx" "$TG_MASK_OUT" "telegram token masking"

# 9. Test shims creation and isolation behavior
export TACHYON_FPTN_STATE_DIR="$WORK_DIR/fptn_state"
mkdir -p "$TACHYON_FPTN_STATE_DIR"
TACHYON_LIB_DIR="$TACHYON_LIB" ucode_run "$FPTN_RUNTIME_UC" install-shims

SHIMS_DIR="$TACHYON_FPTN_STATE_DIR/bin"
[ -x "$SHIMS_DIR/ip" ] || fail "ip shim not created or not executable"
[ -x "$SHIMS_DIR/sed" ] || fail "sed shim not created or not executable"
[ -x "$SHIMS_DIR/iptables" ] || fail "iptables shim not created or not executable"
[ -x "$SHIMS_DIR/chattr" ] || fail "chattr shim not created or not executable"

# Test ip shim blocks default route replace/del/add
IP_REPLACE_STATUS=0
"$SHIMS_DIR/ip" route replace default dev tun-fptn scope link || IP_REPLACE_STATUS=$?
assert_eq "0" "$IP_REPLACE_STATUS" "ip shim should return 0 for route replace default"

IP_DEL_STATUS=0
"$SHIMS_DIR/ip" route del default dev tun-fptn scope link || IP_DEL_STATUS=$?
assert_eq "0" "$IP_DEL_STATUS" "ip shim should return 0 for route del default"

# Test sed shim blocks modifying /etc/resolv.conf
SED_STATUS=0
"$SHIMS_DIR/sed" -i '1i nameserver 172.20.0.1' /etc/resolv.conf || SED_STATUS=$?
assert_eq "0" "$SED_STATUS" "sed shim should return 0 for resolv.conf"

# Test dummy shims exit 0
IPT_STATUS=0
"$SHIMS_DIR/iptables" -A OUTPUT -p udp --dport 53 -j DROP || IPT_STATUS=$?
assert_eq "0" "$IPT_STATUS" "iptables shim should return 0"

echo "fptn component tests passed"

