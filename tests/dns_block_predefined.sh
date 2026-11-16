#!/usr/bin/env bash
# Verify generated DNS block records for tachyon-core. Set
# TACHYON_TEST_CORE_BIN to also check and query a real tachyon-core binary.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -euo pipefail

if [ -n "${TACHYON_TEST_CORE_BIN:-}" ]; then
  acquire_core_proc_lock
  trap 'release_core_proc_lock; cleanup' EXIT
fi

if command -v python3 >/dev/null 2>&1; then
  python3 "$ROOT_DIR/tests/lib/dns_block_predefined.py" "$TACHYON_LIB" "$WORK_DIR"
else
  cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"] },
  "section": [{ ".name": "block", ".type": "section", "enabled": "1", "action": "block", "domain_suffix": ["blocked.example"], "source_ip_cidr": ["127.0.0.1"] }]
}
JSON
  version="0.5.7"
  printf '%s' "$version" >"$WORK_DIR/version"
  out="$WORK_DIR/tachyon-core-${version}.json"
  TACHYON_LIB="$TACHYON_LIB" \
    TACHYON_CORE_VERSION_FILE="$WORK_DIR/version" \
    TACHYON_DNS_FAILOVER_STATE_FILE="$WORK_DIR/no-dns-state" \
    TACHYON_SECTION_FAIL_STATE_FILE="$WORK_DIR/no-fail-state" \
    ucode -L "$TACHYON_LIB" "$TACHYON_LIB/tachyon_core/generator.uc" generate-config-fixture "$WORK_DIR/fixture.json" "$out" 127.0.0.1 0
  node -e '
    const fs = require("fs");
    const [version, out] = process.argv.slice(1);
    const cfg = JSON.parse(fs.readFileSync(out, "utf8"));
    const rules = ((cfg.dns && cfg.dns.rules) || []).filter(r => r.action === "predefined" && r.answer);
    if (rules.length !== 2) throw new Error(`expected 2 rules for tachyon-core, got ${rules.length}`);
    for (const [qtype, ip] of [["A", "0.0.0.0"], ["AAAA", "::"]]) {
      const rule = rules.find(r => Array.isArray(r.query_type) && r.query_type[0] === qtype);
      if (!rule || rule.rcode !== "NOERROR" || !(rule.source_ip_cidr || []).includes("127.0.0.1/32")) {
        throw new Error(`bad rule for tachyon-core ${qtype}`);
      }
      const ans = rule.answer[0];
      if (!ans || ans.ttl !== 15 || ans.value !== ip) throw new Error(`bad tachyon-core answer: ${JSON.stringify(ans)}`);
    }
    console.log(`PASS: DNS block records for tachyon-core ${version}`);
  ' "$version" "$out"
fi
