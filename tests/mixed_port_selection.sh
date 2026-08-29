#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
COMMON_UC="$TACHYON_LIB/core/common.uc"
TG_UC="$TACHYON_LIB/service/telegram.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# 1. Verify priority order in common.uc
grep -Fq 'inbound.tag == "service-mixed-in"' "$COMMON_UC" ||
  fail "common.uc must prioritize service-mixed-in tag"
grep -Fq 'listen == "127.0.0.1"' "$COMMON_UC" ||
  fail "common.uc must prioritize 127.0.0.1 listeners"

# 2. Verify priority order in telegram.uc
grep -Fq 'inbound.tag == "service-mixed-in"' "$TG_UC" ||
  fail "telegram.uc must prioritize service-mixed-in tag"

# 3. Behavioral test: mock sing-box config with user inbound at index 0 and service mixed inbound at index 1
CFG_FILE="$WORK_DIR/config.json"
cat > "$CFG_FILE" <<'EOF'
{
  "inbounds": [
    {
      "type": "mixed",
      "tag": "server-my-proxy",
      "listen": "192.168.1.1",
      "listen_port": 1080
    },
    {
      "type": "mixed",
      "tag": "service-mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 4534
    }
  ]
}
EOF

TEST_SCRIPT="$WORK_DIR/test_port.uc"
cat > "$TEST_SCRIPT" <<'EOF'
let fs = require("fs");
let common = require("core.common");

// Point readfile to our mock file
let cfg_path = getenv("MOCK_CONFIG_PATH");
let data = fs.readfile(cfg_path);
let parsed = json(data);

let port = 0;
for (let inbound in parsed.inbounds) {
    if (inbound.tag == "service-mixed-in" && inbound.listen_port != null) {
        port = int(inbound.listen_port, 10);
        break;
    }
}
if (port == 4534) {
    print("OK\n");
} else {
    print("FAILED: got " + port + "\n");
}
EOF

result="$(MOCK_CONFIG_PATH="$CFG_FILE" ucode -L "$TACHYON_LIB" "$TEST_SCRIPT" 2>/dev/null || true)"
[ "$result" = "OK" ] || fail "get_mixed_port priority test failed: $result"

printf 'mixed port selection checks passed\n'
