#!/usr/bin/env bash
set -eo pipefail

# Issue #82: with FakeIP on, a proxy endpoint's own hostname could be answered
# from the FakeIP pool. A connection section routing `domain_suffix
# example.net` also covered the endpoint `cdn.example.net`, so the internal DNS
# lookup for that endpoint matched the section rule, returned 198.18.0.0/15, and
# sing-box then dialled the FakeIP and timed out.
#
# The endpoint list is rebuilt from the generated config on every run, so it
# follows endpoint changes in a subscription with no manual exclusion.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -d "$ROOT_DIR/tachyon/files/usr/lib" ]; then
  TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
else
  TACHYON_LIB="/usr/lib/tachyon"
fi
GENERATOR_UC="$TACHYON_LIB/singbox/generator.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# The outbound shape mirrors a subscription node: vless with a hostname server.
cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings", ".type": "settings", "enabled": "1",
    "dns_type": "udp", "dns_server": [ "1.1.1.1" ],
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "prox", ".type": "section", "enabled": "1", "action": "connection",
      "domain_suffix": [ "example.net" ],
      "outbound_jsons": [ "{\"type\":\"vless\",\"tag\":\"prox-out\",\"server\":\"cdn.example.net\",\"server_port\":443,\"uuid\":\"00000000-0000-0000-0000-000000000001\",\"tls\":{\"enabled\":true,\"server_name\":\"cdn.example.net\"}}" ]
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
  "$WORK_DIR/fixture.json" "$OUTPUT" "127.0.0.1"

JSON_VALUE="$(cat "$OUTPUT")" node <<'NODE'
const cfg = JSON.parse(process.env.JSON_VALUE);
const problems = [];

// The rule must be a real DNS rule, not a string: `+` on two ucode arrays
// silently coerces to a string, which is what this test first caught.
const rules = (cfg.dns && cfg.dns.rules) || [];
if (!Array.isArray(rules)) {
  console.error(`FAIL: dns.rules is ${typeof rules}, expected an array`);
  process.exit(1);
}

const first = rules[0] || {};
const domains = Array.isArray(first.domain) ? first.domain : [];
if (!domains.includes("cdn.example.net"))
  problems.push(`dns.rules[0] must cover the proxy endpoint, got ${JSON.stringify(first.domain)}`);
if (first.server !== "bootstrap-dns-server")
  problems.push(`dns.rules[0] must resolve via a real resolver, got ${JSON.stringify(first.server)}`);

// The section rule that would hand out a FakeIP must come later.
const later = rules.findIndex(
  (r) => r && r.server && /fakeip|routed-dns/.test(r.server),
);
if (later <= 0)
  problems.push(`a section/FakeIP DNS rule still precedes the endpoint rule (index ${later})`);

// Endpoints are matched case-insensitively and de-duplicated.
if (domains.filter((d) => d === "cdn.example.net").length !== 1)
  problems.push("endpoint domain must appear exactly once");

// The internal guard must never reach the config.
if (JSON.stringify(cfg).includes("__proxy_endpoint_dns_rule"))
  problems.push("internal marker leaked into the generated config");

if (problems.length) {
  for (const p of problems) console.error("FAIL: " + p);
  process.exit(1);
}
console.log(`endpoint DNS rule first, covering ${domains.length} endpoint domain(s)`);
NODE

if command -v sing-box >/dev/null 2>&1; then
  sing-box check -c "$OUTPUT" >/dev/null 2>&1 ||
    fail "generated config rejected by $(sing-box version | head -1)"
  printf '  accepted by %s\n' "$(sing-box version | head -1)"
fi

printf 'proxy endpoint fakeip exclusion checks passed\n'
