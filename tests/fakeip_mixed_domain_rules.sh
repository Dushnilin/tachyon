#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# Issue #184: FakeIP not applied to some custom domains when using tachyon-core.
# When a route section has multiple domain condition types (e.g. domain_suffix
# and domain_keyword), grouping them into a single DNS rule causes engines that
# evaluate fields with AND semantics to reject domains matching only one type.
#
# Tachyon must emit separate DNS rules per domain condition type so that each
# matcher is evaluated independently (OR semantics) across all engine variants.

if [ -d "$ROOT_DIR/tachyon/files/usr/lib" ]; then
  TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
else
  TACHYON_LIB="/usr/lib/tachyon"
fi
GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"
trap 'rm -rf "$WORK_DIR"' EXIT

cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings", ".type": "settings", "enabled": "1",
    "dns_type": "udp", "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "main", ".type": "section", "enabled": "1", "action": "connection",
      "domain_suffix": [ "perplexity.ai", "oracle.com" ],
      "domain_keyword": [ "customkeyword" ],
      "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"main-out\"}" ]
    },
    {
      ".name": "other", ".type": "section", "enabled": "1", "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"other-out\"}" ]
    }
  ]
}
JSON

OUTPUT="$WORK_DIR/config.json"
mkdir -p "${OUTPUT}.section-cache" "${OUTPUT}.rulesets"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$OUTPUT" "127.0.0.1" "0" "1"

JSON_VALUE="$(cat "$OUTPUT")" node <<'NODE'
const cfg = JSON.parse(process.env.JSON_VALUE);
const dnsRules = (cfg.dns && cfg.dns.rules) || [];

// Ensure NO DNS rule has BOTH domain_suffix AND domain_keyword simultaneously
for (const rule of dnsRules) {
  if (rule.domain_suffix && rule.domain_keyword) {
    console.error("FAIL: Found DNS rule combining domain_suffix and domain_keyword:", JSON.stringify(rule));
    process.exit(1);
  }
}

// Verify there is a rule with domain_suffix and a rule with domain_keyword
const suffixRule = dnsRules.find((r) => Array.isArray(r.domain_suffix) && r.domain_suffix.includes("perplexity.ai"));
const keywordRule = dnsRules.find((r) => Array.isArray(r.domain_keyword) && r.domain_keyword.includes("customkeyword"));

if (!suffixRule) {
  console.error("FAIL: Missing DNS rule for domain_suffix containing perplexity.ai");
  process.exit(1);
}

if (!keywordRule) {
  console.error("FAIL: Missing DNS rule for domain_keyword containing customkeyword");
  process.exit(1);
}

if (suffixRule.server !== "fakeip-server" || keywordRule.server !== "fakeip-server") {
  console.error("FAIL: Expected server to be fakeip-server, got:", suffixRule.server, keywordRule.server);
  process.exit(1);
}

console.log("PASS: DNS rules for mixed domain conditions generated separately with FakeIP");
NODE
