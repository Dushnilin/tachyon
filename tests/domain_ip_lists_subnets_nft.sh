#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# 1. Test split-domain-subnet-file with plain IPs, CIDRs, and domains
cat >"$WORK_DIR/mixed.txt" <<'EOF'
# Sample list with mixed domains, raw IPs, and subnets
example.com
1.2.3.4
sub.domain.org
192.168.10.0/24
2001:db8::1
2606:4700::/32
test-site.ru
EOF

DOMAINS_OUT="$WORK_DIR/domains.txt"
SUBNETS_OUT="$WORK_DIR/subnets.txt"

ucode -L "$TACHYON_LIB" "$TACHYON_LIB/nft/apply.uc" split-domain-subnet-file \
  "$WORK_DIR/mixed.txt" "$DOMAINS_OUT" "$SUBNETS_OUT"

grep -q "example.com" "$DOMAINS_OUT" || fail "domains.txt missing example.com"
grep -q "sub.domain.org" "$DOMAINS_OUT" || fail "domains.txt missing sub.domain.org"
grep -q "test-site.ru" "$DOMAINS_OUT" || fail "domains.txt missing test-site.ru"

# Crucial check: plain IPs must NOT be in domains.txt!
if grep -q "1.2.3.4" "$DOMAINS_OUT"; then
  fail "1.2.3.4 was erroneously placed in domains.txt"
fi
if grep -q "2001:db8::1" "$DOMAINS_OUT"; then
  fail "2001:db8::1 was erroneously placed in domains.txt"
fi

grep -q "1.2.3.4" "$SUBNETS_OUT" || fail "subnets.txt missing raw IP 1.2.3.4"
grep -q "192.168.10.0/24" "$SUBNETS_OUT" || fail "subnets.txt missing subnet 192.168.10.0/24"
grep -q "2001:db8::1" "$SUBNETS_OUT" || fail "subnets.txt missing IPv6 2001:db8::1"
grep -q "2606:4700::/32" "$SUBNETS_OUT" || fail "subnets.txt missing IPv6 CIDR"

# 2. Test normalize_plain_ruleset_value in routing/rulesets.uc
ucode -L "$TACHYON_LIB" -e '
let rulesets = require("routing.rulesets");
let ip = require("core.ip");

// IP addresses must return null for kind == "domains"
let dom_res = rulesets.normalize_plain_ruleset_value("1.2.3.4", "domains");
if (dom_res != null) {
    warn("FAIL: 1.2.3.4 returned non-null domain: ", dom_res, "\n");
    exit(1);
}

let cidr_res = rulesets.normalize_plain_ruleset_value("10.0.0.0/8", "domains");
if (cidr_res != null) {
    warn("FAIL: 10.0.0.0/8 returned non-null domain: ", cidr_res, "\n");
    exit(1);
}

let sub_res = rulesets.normalize_plain_ruleset_value("1.2.3.4", "subnets");
if (sub_res != "1.2.3.4") {
    warn("FAIL: 1.2.3.4 was not accepted as subnet\n");
    exit(1);
}
' || fail "normalize_plain_ruleset_value check failed"

# 3. Test validator accepts .txt alongside .lst
ucode -L "$TACHYON_LIB" "$TACHYON_LIB/config/validator.uc" plain-domain-ip-list-reference-valid "/etc/tachyon/list.txt" || fail "/etc/tachyon/list.txt was rejected by validator"
ucode -L "$TACHYON_LIB" "$TACHYON_LIB/config/validator.uc" plain-domain-ip-list-reference-valid "/etc/tachyon/list.lst" || fail "/etc/tachyon/list.lst was rejected by validator"
ucode -L "$TACHYON_LIB" "$TACHYON_LIB/config/validator.uc" plain-domain-ip-list-reference-valid "https://example.com/list.txt" || fail "https://example.com/list.txt was rejected by validator"

if ucode -L "$TACHYON_LIB" "$TACHYON_LIB/config/validator.uc" plain-domain-ip-list-reference-valid "/etc/tachyon/list.invalid" >/dev/null 2>&1; then
    fail "/etc/tachyon/list.invalid was accepted by validator"
fi

# 4. Test that nft_populate_runtime_set_for_section populates subnets from domain_ip_lists (.txt and .lst)
NFT_LOG="$WORK_DIR/nft.log"
LOGGER_LOG="$WORK_DIR/logger.log"
export NFT_LOG LOGGER_LOG

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/nft" <<'NFT'
#!/usr/bin/env bash
set -eo pipefail
{
  printf 'nft'
  for arg in "$@"; do
    printf '\t%s' "$arg"
  done
  printf '\n'
} >> "${NFT_LOG:?}"

if [ "$1" = "-f" ] && [ -f "$2" ]; then
  while read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^add[[:space:]]+element[[:space:]]+inet[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+(.*)$ ]]; then
      printf 'nft\tadd\telement\tinet\t%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" >> "${NFT_LOG:?}"
    else
      printf '%s\n' "$line" >> "${NFT_LOG:?}"
    fi
  done < "$2"
fi
exit 0
NFT
chmod +x "$WORK_DIR/bin/nft"

cat >"$WORK_DIR/bin/logger" <<'LOGGER'
#!/usr/bin/env bash
exit 0
LOGGER
chmod +x "$WORK_DIR/bin/logger"

cat >"$WORK_DIR/bin/ip" <<'IP'
#!/usr/bin/env bash
exit 0
IP
chmod +x "$WORK_DIR/bin/ip"

OLD_PATH="$PATH"
export PATH="$WORK_DIR/bin:$PATH"

cat >"$WORK_DIR/subnets1.txt" <<'EOF'
# Local subnets in .txt
198.51.100.77
203.0.113.0/24
2001:db8::77
domain-in-subnets.com
EOF

cat >"$WORK_DIR/subnets2.lst" <<'EOF'
# Local subnets in .lst with port
198.51.100.88
EOF

cat >"$WORK_DIR/test-populate-fixture.json" <<JSON
{
  "settings": {
    "source_network_interfaces": [ "br-lan" ]
  },
  "section": [
    {
      ".name": "sec_txt",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "domain_ip_lists": [ "$WORK_DIR/subnets1.txt" ]
    },
    {
      ".name": "sec_lst_ports",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "ports": [ "443" ],
      "domain_ip_lists": [ "$WORK_DIR/subnets2.lst" ]
    }
  ]
}
JSON

: > "$NFT_LOG"
ucode -L "$TACHYON_LIB" "$TACHYON_LIB/nft/apply.uc" nft-populate-runtime-sets-fixture \
  "$WORK_DIR/test-populate-fixture.json" 1 "" TachyonTable tachyon_subnets tachyon_ports tachyon_ip_ports tachyon_interfaces localv4 0x00100000

grep -q "tachyon_rule_sec_txt_subnets.*198.51.100.77" "$NFT_LOG" || fail "sec_txt IPv4 subnets from .txt missing in nft set"
grep -q "tachyon_rule_sec_txt_subnets6.*2001:db8::77" "$NFT_LOG" || fail "sec_txt IPv6 subnets from .txt missing in nft set"
grep -q "198.51.100.88 . 443" "$NFT_LOG" || fail "sec_lst_ports scoped ip-port missing in nft set"
if grep -q "domain-in-subnets.com" "$NFT_LOG"; then
  fail "domain name unexpectedly placed in nft ip set"
fi
mkdir -p /tmp/sing-box/rulesets
cat >/tmp/sing-box/rulesets/sec_compiled-lists-ruleset.json <<'JSON'
{
  "version": 1,
  "rules": [
    {
      "ip_cidr": [ "198.51.100.99", "2001:db8::99" ]
    }
  ]
}
JSON

cat >"$WORK_DIR/test-compiled-fixture.json" <<JSON
{
  "settings": {
    "source_network_interfaces": [ "br-lan" ]
  },
  "section": [
    {
      ".name": "sec_compiled",
      ".type": "section",
      "enabled": "1",
      "action": "proxy"
    }
  ]
}
JSON

: > "$NFT_LOG"
ucode -L "$TACHYON_LIB" "$TACHYON_LIB/nft/apply.uc" nft-populate-runtime-sets-fixture \
  "$WORK_DIR/test-compiled-fixture.json" 1 "" TachyonTable tachyon_subnets tachyon_ports tachyon_ip_ports tachyon_interfaces localv4 0x00100000

grep -q "tachyon_rule_sec_compiled_subnets.*198.51.100.99" "$NFT_LOG" || fail "sec_compiled IPv4 subnets from compiled ruleset missing in nft set"
grep -q "tachyon_rule_sec_compiled_subnets6.*2001:db8::99" "$NFT_LOG" || fail "sec_compiled IPv6 subnets from compiled ruleset missing in nft set"

rm -rf /tmp/sing-box/rulesets/sec_compiled-lists-ruleset.json

export PATH="$OLD_PATH"

echo "PASS: domain_ip_lists_subnets_nft"
