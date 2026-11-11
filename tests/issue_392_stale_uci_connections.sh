#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

MIGRATION="$TACHYON_LIB/config/migration.uc"
GENERATOR="$TACHYON_LIB/tachyon_core/generator.uc"

# 1. Subscription outbound_source with stale proxy_links + section with stale inline outbound_jsons
cat >"$WORK_DIR/issue392_input.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_version": "1.0.5",
    "dns_server": "1.1.1.1",
    "applied_migrations": [
      "interface_sections",
      "enable_component_checks",
      "http_connection_urls",
      "dns_hosts_to_option",
      "global_hosts_to_section",
      "orphan_section_interface_cleanup",
      "ensure_dns_server_defaults",
      "engine_identity_tachyon_core",
      "modular_entities_v1",
      "priority_levels_to_outbound_groups"
    ]
  },
  "outbound_source": [
    {
      ".name": "xhttp_443",
      ".type": "outbound_source",
      "enabled": "1",
      "name": "xhttp 443",
      "source_type": "subscription",
      "url": "https://sub.example.com/api/v1/sub",
      "proxy_links": [
        "vless://11111111-1111-4111-8111-111111111111@stale-link.example:443?security=tls#StaleLinkNode"
      ]
    }
  ],
  "section": [
    {
      ".name": "empaer",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_source_refs": [ "xhttp_443" ],
      "outbound_jsons": [
        "{\"type\":\"vless\",\"tag\":\"stale-empaer-json\",\"server\":\"stale-empaer.example\",\"server_port\":443,\"uuid\":\"22222222-2222-4222-8222-222222222222\"}"
      ],
      "selector_proxy_links": [
        "vless://33333333-3333-4333-8333-333333333333@stale-sec-link.example:443?security=tls#StaleSecLink"
      ]
    },
    {
      ".name": "main",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_source_refs": [ "xhttp_443" ],
      "outbound_jsons": [
        "{\"type\":\"vless\",\"tag\":\"stale-main-json\",\"server\":\"stale-main.example\",\"server_port\":443,\"uuid\":\"44444444-4444-4444-8444-444444444444\"}"
      ]
    }
  ]
}
JSON

# Verify connections.uc ignores stale fields even before migration runs
TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" -e '
let fs = require("fs");
let connections = require("config.connections");
let data = json(fs.readfile("'"$WORK_DIR"'/issue392_input.json"));
connections.set_item_sections_from_data(data);
for (let sec in data.section) {
    let urls = connections.connection_urls(sec);
    if (length(urls) != 0) {
        warn("Expected 0 connection_urls for " + sec[".name"] + ", got: " + sprintf("%J", urls) + "\n");
        exit(1);
    }
    let jsons = connections.outbound_jsons(sec);
    if (length(jsons) != 0) {
        warn("Expected 0 outbound_jsons for " + sec[".name"] + ", got: " + sprintf("%J", jsons) + "\n");
        exit(1);
    }
}
'

# Verify migration cleans up stale proxy_links on subscription outbound_source
TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/issue392_input.json" >"$WORK_DIR/issue392_migrated.json"

node - "$WORK_DIR/issue392_migrated.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const src = (out.config.outbound_source || []).find(s => s['.name'] === 'xhttp_443');
if (!src) {
  console.error('missing xhttp_443 outbound_source after migration');
  process.exit(1);
}
if (Object.prototype.hasOwnProperty.call(src, 'proxy_links')) {
  console.error('stale proxy_links was not removed from subscription outbound_source:', src);
  process.exit(1);
}
if (src.url !== 'https://sub.example.com/api/v1/sub') {
  console.error('subscription url was altered unexpectedly:', src);
  process.exit(1);
}
for (const secName of ['empaer', 'main']) {
  const sec = (out.config.section || []).find(s => s['.name'] === secName);
  if (!sec) {
    console.error('missing section after migration:', secName);
    process.exit(1);
  }
  if (Object.prototype.hasOwnProperty.call(sec, 'outbound_jsons')) {
    console.error(`stale outbound_jsons was not removed from section ${secName}:`, sec);
    process.exit(1);
  }
  if (Object.prototype.hasOwnProperty.call(sec, 'selector_proxy_links')) {
    console.error(`stale selector_proxy_links was not removed from section ${secName}:`, sec);
    process.exit(1);
  }
}
NODE

# Verify full generated core config with subscription cache contains neither stale links nor stale inline JSONs
mkdir -p "$WORK_DIR/sub_cache"
cat >"$WORK_DIR/sub_cache_node.json" <<'JSON'
{
  "version": 1,
  "format": "sing-box-json",
  "outbounds": [
    {
      "type": "vless",
      "tag": "sub-live-node",
      "server": "live.example.com",
      "server_port": 443,
      "uuid": "55555555-5555-4555-8555-555555555555"
    }
  ]
}
JSON
cp "$WORK_DIR/sub_cache_node.json" "$WORK_DIR/sub_cache/empaer-subscription-1.json"
printf 'https://sub.example.com/api/v1/sub\n' >"$WORK_DIR/sub_cache/empaer-subscription-1.url"
cp "$WORK_DIR/sub_cache_node.json" "$WORK_DIR/sub_cache/main-subscription-1.json"
printf 'https://sub.example.com/api/v1/sub\n' >"$WORK_DIR/sub_cache/main-subscription-1.url"

TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/sub_cache" \
  TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/sub_cache" \
  TACHYON_LIB="$TACHYON_LIB" \
  ucode -L "$TACHYON_LIB" "$GENERATOR" \
  generate-config-fixture "$WORK_DIR/issue392_input.json" "$WORK_DIR/core_out.json" 127.0.0.42 0 1

if grep -Eq 'stale-link\.example|StaleLinkNode|stale-empaer|stale-main|stale-sec-link' "$WORK_DIR/core_out.json"; then
  fail "generated core config must not include stale UCI proxy_links or inline outbound_jsons"
fi

printf 'issue 392 stale uci connections test passed\n'
