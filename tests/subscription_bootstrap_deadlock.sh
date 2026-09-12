#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$ROOT_DIR/tachyon/files/usr/lib"
VALIDATOR="$LIB_DIR/config/validator.uc"
GENERATOR="$LIB_DIR/singbox/generator.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [ "$expected" != "$actual" ]; then
    printf 'FAIL: %s: expected "%s", got "%s"\n' "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

# 1. Test validator accepts a section downloading through itself
printf 'Testing validator allows section downloading through itself...\n'
cat >"$WORK_DIR/self_download.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": ["77.88.8.8"],
    "bootstrap_dns_server": ["77.88.8.8"]
  },
  "section": [
    {
      ".name": "vpn1",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "subscription_urls": [ "https://example.com/sub" ],
      "subscription_url_settings": "{\"https://example.com/sub\":{\"download_via_proxy_section\":\"vpn1\"}}"
    }
  ]
}
JSON

TACHYON_LIB="$LIB_DIR" ucode -L "$LIB_DIR" "$VALIDATOR" validate-runtime-fixture "$WORK_DIR/self_download.json" "{}" >"$WORK_DIR/val.out" 2>"$WORK_DIR/val.err"

printf 'Validator successfully accepted self-download configuration.\n'

# 2. Test connections.uc includes self-target in subscription_download_targets
printf 'Testing connections.uc subscription_download_targets includes self-target...\n'
ucode -L "$LIB_DIR" -e '
let connections = require("config.connections");
let sections = [
  {
    ".name": "vpn1",
    ".type": "section",
    "enabled": "1",
    "action": "proxy",
    "subscription_urls": [ "https://example.com/sub" ],
    "subscription_url_settings": "{\"https://example.com/sub\":{\"download_via_proxy_enabled\":\"1\",\"download_via_proxy_section\":\"vpn1\"}}"
  }
];
let targets = connections.subscription_download_targets(sections);
for (let t in targets)
  print(t, "\n");
' > "$WORK_DIR/targets.out"

assert_eq "vpn1" "$(cat "$WORK_DIR/targets.out")" "subscription_download_targets should include vpn1"

# 3. Test singbox config generator with deferred section
printf 'Testing singbox config generator skips deferred section...\n'
mkdir -p "$WORK_DIR/runtime"

cat > "$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_server": "1.1.1.1"
  },
  "sections": [
    {
      ".name": "vpn1",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "selector_proxy_links": [ "socks5://127.0.0.1:1080#node1" ]
    },
    {
      ".name": "vpn2",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "subscription_urls": [ "https://example.com/sub2" ],
      "subscription_url_settings": "{\"https://example.com/sub2\":{\"download_via_proxy_enabled\":\"1\",\"download_via_proxy_section\":\"vpn1\"}}"
    }
  ]
}
JSON

# A: Generating config WITHOUT deferring vpn2 must fail (vpn2 has 0 outbounds)
set +e
mkdir -p "$WORK_DIR/config_fail.json.section-cache" "$WORK_DIR/config_fail.json.rulesets"
TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/runtime" \
ucode -L "$LIB_DIR" "$GENERATOR" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$WORK_DIR/config_fail.json" "127.0.0.1" "0" "1" "" >"$WORK_DIR/gen_fail.out" 2>"$WORK_DIR/gen_fail.err"
STATUS_FAIL=$?
set -e
if [ "$STATUS_FAIL" -eq 0 ]; then
  fail "generator should have failed when vpn2 has no outbounds and is not deferred"
fi
if ! grep -Fq "connection section has no usable outbounds" "$WORK_DIR/gen_fail.err"; then
  printf 'gen_fail.err:\n%s\ngen_fail.out:\n%s\n' "$(cat "$WORK_DIR/gen_fail.err")" "$(cat "$WORK_DIR/gen_fail.out")" >&2
  fail "expected 'connection section has no usable outbounds' in error output"
fi

# B: Generating config WITH deferred_sections='vpn2' must SUCCEED!
mkdir -p "$WORK_DIR/config_pass.json.section-cache" "$WORK_DIR/config_pass.json.rulesets"
TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/runtime" \
ucode -L "$LIB_DIR" "$GENERATOR" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$WORK_DIR/config_pass.json" "127.0.0.1" "0" "1" "vpn2" >"$WORK_DIR/gen_pass.out" 2>"$WORK_DIR/gen_pass.err"

if [ ! -s "$WORK_DIR/config_pass.json" ]; then
  fail "generator failed to produce config when vpn2 is deferred"
fi

# Verify generated config has outbounds for vpn1 and NOT broken references to vpn2
node - "$WORK_DIR/config_pass.json" <<'NODE'
const fs = require('fs');
const cfg = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const tags = (cfg.outbounds || []).map(o => o.tag);
console.log("outbound tags:", JSON.stringify(tags));
if (!tags.includes('vpn1-out')) {
  console.error("Generated config must include vpn1-out outbound");
  process.exit(1);
}
if (tags.includes('vpn2-out')) {
  console.error("Generated config must NOT include deferred vpn2-out outbound");
  process.exit(1);
}

const inbounds = (cfg.inbounds || []).map(i => i.tag);
console.log("inbound tags:", JSON.stringify(inbounds));
if (!inbounds.includes('service-subscription-vpn1-in')) {
  console.error("Generated config must include service-subscription-vpn1-in inbound for subscription download");
  process.exit(1);
}
console.log("CONFIG_VERIFIED_OK");
NODE

printf 'subscription_bootstrap_deadlock tests passed successfully\n'
