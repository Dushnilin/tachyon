#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/.." && pwd)"
PARSER_UC="$TACHYON_LIB/subscription/parser.uc"
CACHE_UC="$TACHYON_LIB/subscription/cache.uc"

trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# 1. Test that a subscription with only "Данное приложение не поддерживается" is rejected
cat >"$WORK_DIR/stub_uri.txt" <<'EOF'
vless://00000000-0000-0000-0000-000000000000@127.0.0.1:443?security=none#%D0%94%D0%B0%D0%BD%D0%BD%D0%BE%D0%B5%20%D0%BF%D1%80%D0%B8%D0%BB%D0%BE%D0%B6%D0%B5%D0%BD%D0%B8%D0%B5%20%D0%BD%D0%B5%20%D0%BF%D0%BE%D0%B4%D0%B4%D0%B5%D1%80%D0%B6%D0%B8%D0%B2%D0%B0%D0%B5%D1%82%D1%81%D1%8F
EOF

if ucode -L "$TACHYON_LIB" "$PARSER_UC" normalize-content-validated "$WORK_DIR/stub_uri.txt" "$WORK_DIR/out_stub.json" >/dev/null 2>&1; then
  fail "normalize-content-validated should reject subscription with only 'Данное приложение не поддерживается'"
fi

# 2. Test English variant: "This app is not supported. Use Happ"
cat >"$WORK_DIR/stub_en.txt" <<'EOF'
vless://00000000-0000-0000-0000-000000000000@127.0.0.1:443?security=none#Unsupported%20client%20-%20Use%20Happ
EOF

if ucode -L "$TACHYON_LIB" "$PARSER_UC" normalize-content-validated "$WORK_DIR/stub_en.txt" "$WORK_DIR/out_stub_en.json" >/dev/null 2>&1; then
  fail "normalize-content-validated should reject English unsupported client notice"
fi

# 3. Test sing-box JSON with only stub outbound
cat >"$WORK_DIR/stub_singbox.json" <<'EOF'
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "⚠️ Данное приложение не поддерживается",
      "server": "127.0.0.1",
      "server_port": 443,
      "uuid": "00000000-0000-0000-0000-000000000000"
    }
  ]
}
EOF

if ucode -L "$TACHYON_LIB" "$PARSER_UC" normalize-content-validated "$WORK_DIR/stub_singbox.json" "$WORK_DIR/out_stub_sb.json" >/dev/null 2>&1; then
  fail "normalize-content-validated should reject singbox JSON with stub outbound"
fi

# 4. Test Clash YAML with only stub outbound
cat >"$WORK_DIR/stub_clash.yaml" <<'EOF'
proxies:
  - name: "Данное приложение не поддерживается"
    type: vless
    server: 127.0.0.1
    port: 443
    uuid: 00000000-0000-0000-0000-000000000000
EOF

if ucode -L "$TACHYON_LIB" "$PARSER_UC" normalize-content-validated "$WORK_DIR/stub_clash.yaml" "$WORK_DIR/out_stub_clash.json" >/dev/null 2>&1; then
  fail "normalize-content-validated should reject Clash YAML with stub outbound"
fi

# 5. Test mixed subscription: 1 real node + 1 stub node
cat >"$WORK_DIR/mixed_uri.txt" <<'EOF'
vless://11111111-1111-1111-1111-111111111111@vpn.example.com:443?security=none#Valid-Server-DE
vless://00000000-0000-0000-0000-000000000000@127.0.0.1:443?security=none#Данное%20приложение%20не%20поддерживается
EOF

ucode -L "$TACHYON_LIB" "$PARSER_UC" normalize-content-validated "$WORK_DIR/mixed_uri.txt" "$WORK_DIR/out_mixed.json" ||
  fail "normalize-content-validated should accept mixed subscription with valid nodes"

ucode -e '
let fs = require("fs");
let doc = json(fs.readfile("'"$WORK_DIR/out_mixed.json"'"));
let list = doc.outbounds || [];
if (length(list) != 1) {
    print("Expected 1 valid outbound after filtering stub, got " + length(list) + "\n");
    exit(1);
}
if (list[0].tag != "Valid-Server-DE" || list[0].server != "vpn.example.com") {
    print("Unexpected outbound content: " + sprintf("%J", list[0]) + "\n");
    exit(2);
}
' || fail "Failed to filter out stub node from mixed subscription"

# 6. Test validate-subscription CLI mode directly
if ucode -L "$TACHYON_LIB" "$PARSER_UC" validate-subscription "$WORK_DIR/stub_singbox.json" >/dev/null 2>&1; then
  fail "validate-subscription CLI should return error for stub-only JSON"
fi

ucode -L "$TACHYON_LIB" "$PARSER_UC" validate-subscription "$WORK_DIR/out_mixed.json" >/dev/null ||
  fail "validate-subscription CLI should return success for valid JSON"

# 7. Test programmatic validate_subscription in parser module
cat >"$WORK_DIR/test_validate.uc" <<'EOF'
let parser = require("subscription.parser");
let stub_file = ARGV[0];
let valid_file = ARGV[1];

if (parser.validate_subscription(stub_file)) {
    print("validate_subscription must return false for stub JSON\n");
    exit(1);
}
if (!parser.validate_subscription(valid_file)) {
    print("validate_subscription must return true for valid JSON\n");
    exit(2);
}
exit(0);
EOF

ucode -L "$TACHYON_LIB" "$WORK_DIR/test_validate.uc" "$WORK_DIR/stub_singbox.json" "$WORK_DIR/out_mixed.json" ||
  fail "subscription validation cache checks failed"

echo "subscription unsupported stub checks passed"

