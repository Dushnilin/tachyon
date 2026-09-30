#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/.." && pwd)"
RULESETS_UC="$TACHYON_LIB/singbox/rulesets.uc"
GENERATOR_UC="$TACHYON_LIB/singbox/generator.uc"

trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# 1. Test is-valid-srs-file with invalid files
touch "$WORK_DIR/empty_zero.srs"
if ucode -L "$TACHYON_LIB" "$RULESETS_UC" is-valid-srs-file "$WORK_DIR/empty_zero.srs" >/dev/null 2>&1; then
  fail "zero-byte file must not be recognized as valid SRS"
fi

printf '<html>404 Not Found</html>' > "$WORK_DIR/html_error.srs"
if ucode -L "$TACHYON_LIB" "$RULESETS_UC" is-valid-srs-file "$WORK_DIR/html_error.srs" >/dev/null 2>&1; then
  fail "HTML error page must not be recognized as valid SRS"
fi

# 2. Test ensure-empty-srs-stub
STUB_TARGET="$WORK_DIR/rulesets/community-russia_inside.srs"
ucode -L "$TACHYON_LIB" "$RULESETS_UC" ensure-empty-srs-stub "$STUB_TARGET" || \
  fail "ensure-empty-srs-stub failed to create stub"

[ -f "$STUB_TARGET" ] || fail "stub target file was not created"

size=$(wc -c < "$STUB_TARGET" | tr -d '[:space:]')
[ "$size" -eq 17 ] || fail "stub file size is $size, expected 17 bytes"

ucode -L "$TACHYON_LIB" "$RULESETS_UC" is-valid-srs-file "$STUB_TARGET" >/dev/null || \
  fail "created stub must be recognized as valid SRS"

# 3. Test that generator produces type: local when stub is present
cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "HyDE",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\"}" ],
      "community_lists": [ "russia_inside" ]
    }
  ]
}
JSON

output="$WORK_DIR/out.json"
mkdir -p "$output.section-cache" "$output.rulesets"

# Copy the stub into the generator's rulesets directory (simulating startup preparation)
cp "$STUB_TARGET" "$output.rulesets/community-russia_inside.srs"

ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$output" "127.0.0.1" "0" "1"

# The generated route.rule_set MUST be "type": "local" pointing to the stub
grep -Fq '"type": "local"' "$output" || \
  fail "ruleset must be local when stub exists"

grep -Fq 'community-russia_inside.srs' "$output" || \
  fail "ruleset must point to community-russia_inside.srs"

if grep -Fq '"type": "remote"' "$output"; then
  fail "must not emit remote ruleset when local stub is present"
fi

# 4. Verify candidate generation in core.url prioritizes gh-proxy and handles releases
url_candidates=$(ucode -L "$TACHYON_LIB" -e '
let url = require("core.url");
let c = url.download_candidates("https://github.com/itdoginfo/allow-domains/releases/latest/download/russia_inside.srs");
for (let u in c) print(u, "\n");
')

echo "$url_candidates" | grep -Fq 'https://gh-proxy.com/https://github.com/itdoginfo/allow-domains/releases/latest/download/russia_inside.srs' || \
  fail "download_candidates must include gh-proxy mirror for releases"

if echo "$url_candidates" | grep -Fq 'cdn.jsdelivr.net'; then
  fail "download_candidates must not include jsdelivr for release assets"
fi

echo "ALL cold_boot_community_stub tests passed successfully"
