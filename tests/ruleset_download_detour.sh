#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/.." && pwd)"
GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"

trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Remote rule-set downloads ride on the section outbound or global download proxy
# via http_clients (default_http_client: "ruleset-http") on tachyon-core.
assert_downloads_via() {
  local output="$1" outbound="$2" label="$3"
  grep -Fq "\"download_detour\": \"$outbound\"" "$output" && return 0
  grep -Fq "\"tag\": \"tachyon-download-$outbound\"," "$output" &&
    grep -Fq "\"detour\": \"$outbound\"" "$output" && return 0
  fail "$label"
}

refuses_download_via() {
  local output="$1" outbound="$2" label="$3"
  if grep -Fq "\"download_detour\": \"$outbound\"" "$output"; then
    fail "$label (download_detour)"
  fi
  if grep -Fq "\"detour\": \"$outbound\"" "$output"; then
    fail "$label (http_clients)"
  fi
}

# 1. Verify remote rule_set downloads through section's proxy outbound
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
      ".name": "myproxy",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\"}" ],
      "community_lists": [ "google_ai" ]
    }
  ]
}
JSON

output="$WORK_DIR/out.json"
mkdir -p "$output.section-cache" "$output.rulesets"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$output" "127.0.0.1" "0" "1"

assert_downloads_via "$output" "myproxy-out" \
  "remote community ruleset must automatically download via the section outbound"

# 1b. Verify custom remote rule_sets URL also downloads through section's proxy outbound
cat >"$WORK_DIR/fixture-custom-rs.json" <<'JSON'
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
      ".name": "myproxy",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\"}" ],
      "rule_set": [ "https://example.com/custom-domains.srs" ]
    }
  ]
}
JSON

output_custom="$WORK_DIR/out_custom.json"
mkdir -p "$output_custom.section-cache" "$output_custom.rulesets"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture-custom-rs.json" "$output_custom" "127.0.0.1" "0" "1"

assert_downloads_via "$output_custom" "myproxy-out" \
  "remote custom ruleset must automatically download via the section outbound"

# 2. Verify download_via_proxy fallback selects first enabled proxy section
cat >"$WORK_DIR/fixture-detour-enabled.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "download_lists_via_proxy": "1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "first_proxy",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\"}" ]
    },
    {
      ".name": "other_sec",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\"}" ],
      "community_lists": [ "google_ai" ]
    }
  ]
}
JSON

output2="$WORK_DIR/out2.json"
mkdir -p "$output2.section-cache" "$output2.rulesets"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture-detour-enabled.json" "$output2" "127.0.0.1" "0" "1"

assert_downloads_via "$output2" "first_proxy-out" \
  "global download_lists_via_proxy without explicit section must default to first enabled proxy section"

# 3. Verify http_clients and default_http_client handling on tachyon-core
output_v14="$WORK_DIR/out_v14.json"
mkdir -p "$output_v14.section-cache" "$output_v14.rulesets"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$output_v14" "127.0.0.1" "0" "1"

grep -q '"http_clients"' "$output_v14" || \
  fail "tachyon-core must include http_clients"
grep -q '"default_http_client": "ruleset-http"' "$output_v14" || \
  fail "tachyon-core must configure default_http_client"
if grep -q '"dial_detour"' "$output_v14"; then
  fail "tachyon-core must NEVER contain 'dial_detour' in http_clients"
fi

output_detour_v14="$WORK_DIR/out_detour_v14.json"
mkdir -p "$output_detour_v14.section-cache" "$output_detour_v14.rulesets"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture-detour-enabled.json" "$output_detour_v14" "127.0.0.1" "0" "1"

if grep -q '"dial_detour"' "$output_detour_v14"; then
  fail "tachyon-core must NEVER contain 'dial_detour' with proxy enabled"
fi
grep -q '"detour": "first_proxy-out"' "$output_detour_v14" || \
  fail "tachyon-core http_clients must configure 'detour' field when download_lists_via_proxy is enabled"

# 4. Verify global download_lists_via_proxy skips desync-only sections in favor of proxy sections,
# and is_valid_detour rejects routing_mark / loopback socks / mieru outbounds
cat >"$WORK_DIR/fixture_desync_skip.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "download_lists_via_proxy": "1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "desync_first",
      ".type": "section",
      "enabled": "1",
      "action": "desync",
      "desync_preset": "auto",
      "community_lists": [ "youtube" ]
    },
    {
      ".name": "fallback_proxy",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\"}" ],
      "community_lists": [ "google_ai" ]
    }
  ]
}
JSON

output_desync_skip="$WORK_DIR/out_desync_skip.json"
mkdir -p "$output_desync_skip.section-cache" "$output_desync_skip.rulesets"
TACHYON_CORE_VERSION_OVERRIDE="0.5.7" ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture_desync_skip.json" "$output_desync_skip" "127.0.0.1" "0" "1"

refuses_download_via "$output_desync_skip" "desync_first-out" \
  "global download_lists_via_proxy must skip desync-only sections"
assert_downloads_via "$output_desync_skip" "fallback_proxy-out" \
  "global download_lists_via_proxy must select fallback_proxy-out after skipping desync section"

ucode -L "$TACHYON_LIB" - <<'UCODE'
let gr = require("tachyon_core.generator_routes");
let cfg = {
    outbounds: [
        { type: "vless", tag: "proxy-ok", server: "1.2.3.4", server_port: 443 },
        { type: "socks", tag: "loopback-socks", server: "127.0.0.1", server_port: 1080 },
        { type: "direct", tag: "dpi-out-legacy" },
        { type: "direct", tag: "marked-out", routing_mark: 255 },
        { type: "mieru", tag: "mieru-out", server: "1.2.3.4", server_port: 443 }
    ],
    endpoints: [
        { type: "wireguard", tag: "wg-marked", routing_mark: 255 },
        { type: "wireguard", tag: "wg-clean" }
    ]
};
cfg.outbounds[2].tag = "DPI-out";
if (!gr.is_valid_detour(cfg, "proxy-ok")) die("proxy-ok must be valid detour\n");
if (!gr.is_valid_detour(cfg, "wg-clean")) die("wg-clean must be valid detour\n");
for (let bad in [ "loopback-socks", "DPI-out", "marked-out", "mieru-out", "wg-marked" ]) {
    if (gr.is_valid_detour(cfg, bad))
        die(bad + " must not be valid download detour\n");
}
UCODE

# 5. Verify mieru outbound is rejected as download_detour and http_clients detour
cat >"$WORK_DIR/fixture_mieru.json" <<'JSON'
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
      ".name": "mieru_sec",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"mieru\",\"server\":\"1.2.3.4\",\"server_port\":443}" ],
      "community_lists": [ "google_ai" ]
    }
  ]
}
JSON

output_mieru="$WORK_DIR/out_mieru.json"
mkdir -p "$output_mieru.section-cache" "$output_mieru.rulesets"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture_mieru.json" "$output_mieru" "127.0.0.1" "0" "1"

refuses_download_via "$output_mieru" "mieru_sec-out" \
  "mieru outbound must never be assigned as rule_set download transport (early startup crash)"

output_mieru_v14="$WORK_DIR/out_mieru_v14.json"
mkdir -p "$output_mieru_v14.section-cache" "$output_mieru_v14.rulesets"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture_mieru.json" "$output_mieru_v14" "127.0.0.1" "0" "1"

if grep -q '"detour": "mieru_sec-out"' "$output_mieru_v14"; then
  fail "mieru outbound must never be assigned as http_clients detour"
fi

printf "ruleset download detour checks passed\n"

