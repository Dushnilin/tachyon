#!/usr/bin/env bash
# Verify generated DNS block records for the supported core profiles. Set
# TACHYON_TEST_SING_BOX_BIN to also check and query a real sing-box binary.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -euo pipefail

if [ -n "${TACHYON_TEST_SING_BOX_BIN:-}" ]; then
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
  for spec in "extended:1.14.3-extended-2.7.3" "stable:1.12.0" "stable:1.14.3" "lx:1.14.2-lx.8" "tachyon-core:0.3.4"; do
    profile="${spec%%:*}"
    version="${spec#*:}"
    printf '%s' "$profile" >"$WORK_DIR/variant"
    printf '%s' "$version" >"$WORK_DIR/version"
    out="$WORK_DIR/${profile}-${version}.json"
    TACHYON_LIB="$TACHYON_LIB" \
      SB_VARIANT_STATE_FILE="$WORK_DIR/variant" \
      SB_VERSION_STATE_FILE="$WORK_DIR/version" \
      TACHYON_DNS_FAILOVER_STATE_FILE="$WORK_DIR/no-dns-state" \
      TACHYON_SECTION_FAIL_STATE_FILE="$WORK_DIR/no-fail-state" \
      ucode -L "$TACHYON_LIB" "$TACHYON_LIB/tachyon_core/generator.uc" generate-config-fixture "$WORK_DIR/fixture.json" "$out" 127.0.0.1 0
    node -e '
      const fs = require("fs");
      const [profile, version, out] = process.argv.slice(1);
      const cfg = JSON.parse(fs.readFileSync(out, "utf8"));
      const rules = ((cfg.dns && cfg.dns.rules) || []).filter(r => r.action === "predefined" && r.answer);
      if (rules.length !== 2) throw new Error(`expected 2 rules for ${profile}, got ${rules.length}`);
      for (const [qtype, ip] of [["A", "0.0.0.0"], ["AAAA", "::"]]) {
        const rule = rules.find(r => Array.isArray(r.query_type) && r.query_type[0] === qtype);
        if (!rule || rule.rcode !== "NOERROR" || !(rule.source_ip_cidr || []).includes("127.0.0.1/32")) {
          throw new Error(`bad rule for ${profile} ${qtype}`);
        }
        const ans = rule.answer[0];
        if (profile === "tachyon-core") {
          if (!ans || ans.ttl !== 15 || ans.value !== ip) throw new Error(`bad tachyon-core answer: ${JSON.stringify(ans)}`);
        } else {
          if (ans !== `*. 15 IN ${qtype} ${ip}`) throw new Error(`bad sing-box answer for ${profile}: ${ans}`);
        }
      }
      console.log(`PASS: DNS block records for ${profile} ${version}`);
    ' "$profile" "$version" "$out"
  done
fi
