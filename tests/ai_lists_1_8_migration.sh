#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

MIGRATION="$TACHYON_LIB/config/migration.uc"
[ -f "$MIGRATION" ] || fail "migration.uc not found at $MIGRATION"

# 1. Legacy 1.7.x proxy section using ai_all + google_ai receives google_services once
cat >"$WORK_DIR/case1.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_version": "1.8.0",
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
      "priority_levels_to_outbound_groups",
      "relax_probe_intervals_v1",
      "ensure_tcp_bbr_default",
      "fail_closed_auto_defaults"
    ]
  },
  "section": [
    {
      ".name": "Main",
      ".type": "section",
      "action": "proxy",
      "community_lists": [ "russia_inside" ]
    },
    {
      ".name": "AI",
      ".type": "section",
      "action": "proxy",
      "community_lists": [ "ai_all", "google_ai" ]
    }
  ]
}
JSON

TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/case1.json" >"$WORK_DIR/case1-out.json" ||
  fail "migrate-fixture case1 failed"

node - "$WORK_DIR/case1-out.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const sections = Object.fromEntries(out.config.section.map(s => [s['.name'], s]));
const fail = (m) => { console.error(m); process.exit(1); };

if (!out.config.settings.applied_migrations.includes('ai_lists_1_8'))
  fail('ai_lists_1_8 migration must be recorded');
if (sections.Main.community_lists.includes('google_services'))
  fail('non-AI proxy section Main must not receive google_services');
if (JSON.stringify(sections.AI.community_lists) !== JSON.stringify(['ai_all', 'google_ai', 'google_services']))
  fail(`unexpected AI community_lists: ${JSON.stringify(sections.AI.community_lists)}`);
NODE

# Run second pass to verify idempotency
TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/case1-out.json" --apply >"$WORK_DIR/case1-second.json" 2>/dev/null ||
  TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/case1-out.json" >"$WORK_DIR/case1-second.json"

# 2. If google_services is already configured in Direct, do not duplicate it into AI proxy
cat >"$WORK_DIR/case2.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_version": "1.8.0",
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
      "priority_levels_to_outbound_groups",
      "relax_probe_intervals_v1",
      "ensure_tcp_bbr_default",
      "fail_closed_auto_defaults"
    ]
  },
  "section": [
    {
      ".name": "Direct",
      ".type": "section",
      "action": "direct",
      "community_lists": [ "google_services" ]
    },
    {
      ".name": "AI",
      ".type": "section",
      "action": "proxy",
      "community_lists": [ "ai_all", "google_ai" ]
    }
  ]
}
JSON

TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/case2.json" >"$WORK_DIR/case2-out.json" ||
  fail "migrate-fixture case2 failed"

node - "$WORK_DIR/case2-out.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const sections = Object.fromEntries(out.config.section.map(s => [s['.name'], s]));
if (sections.AI.community_lists.includes('google_services')) {
  console.error('AI section must not get google_services when Direct already owns it');
  process.exit(1);
}
NODE

# 3. Modular condition attached to proxy section using individual AI providers gets qwen, kimi, google_services;
#    direct sections with individual AI providers remain untouched.
cat >"$WORK_DIR/case3.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_version": "1.8.0",
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
      "priority_levels_to_outbound_groups",
      "relax_probe_intervals_v1",
      "ensure_tcp_bbr_default",
      "fail_closed_auto_defaults"
    ]
  },
  "condition": [
    {
      ".name": "cond_ai",
      ".type": "condition",
      "community_lists": [ "openai", "anthropic", "google_ai" ]
    }
  ],
  "section": [
    {
      ".name": "DirectAI",
      ".type": "section",
      "action": "direct",
      "community_lists": [ "openai", "anthropic", "google_ai" ]
    },
    {
      ".name": "ProxyAI",
      ".type": "section",
      "action": "proxy",
      "condition_refs": [ "cond_ai" ]
    }
  ]
}
JSON

TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/case3.json" >"$WORK_DIR/case3-out.json" ||
  fail "migrate-fixture case3 failed"

node - "$WORK_DIR/case3-out.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const cond = out.config.condition.find(c => c['.name'] === 'cond_ai');
const direct = out.config.section.find(s => s['.name'] === 'DirectAI');
const fail = (m) => { console.error(m); process.exit(1); };

for (const needed of ['openai', 'anthropic', 'google_ai', 'qwen', 'kimi', 'google_services']) {
  if (!cond.community_lists.includes(needed))
    fail(`cond_ai missing expected list ${needed}: ${JSON.stringify(cond.community_lists)}`);
}
if (direct.community_lists.includes('kimi') || direct.community_lists.includes('google_services'))
  fail('non-proxy DirectAI section must remain untouched');
NODE

printf 'ai_lists_1_8_migration: all checks passed\n'
