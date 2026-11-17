#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -euo pipefail

command -v ucode >/dev/null 2>&1 || fail "ucode is required"
command -v node >/dev/null 2>&1 || fail "node is required"

MIGRATION_UC="${MIGRATION_UC_OVERRIDE:-$TACHYON_LIB/config/migration.uc}"
[ -f "$MIGRATION_UC" ] || fail "missing migration script: $MIGRATION_UC"

FIXTURE_IN="$WORK_DIR/fixture_50_clones.json"
OUT1="$WORK_DIR/migration_out1.json"
FIXTURE_CLEAN="$WORK_DIR/fixture_clean.json"
OUT2="$WORK_DIR/migration_out2.json"
FIXTURE_ALREADY_CLEAN="$WORK_DIR/fixture_already_clean.json"
OUT_ALREADY_CLEAN="$WORK_DIR/migration_out_already_clean.json"

node -e '
const fs = require("fs");
const outPath = process.argv[1];
const cleanPath = process.argv[2];

const appliedMigrations = [
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
];

const conditions = [
  {
    ".name": "cond_Direct_Games_RU",
    ".type": "condition",
    enabled: "1",
    name: "Игры и РФ напрямую Rules",
    condition_type: "atomic",
    type: "atomic",
    community_lists: ["games", "ru_services"],
    domain_suffix: ["steampowered.com"]
  },
  {
    ".name": "cond_Direct_Games_RU_copy",
    ".type": "condition",
    enabled: "1",
    name: "Игры и РФ напрямую Rules",
    condition_type: "atomic",
    type: "atomic",
    community_lists: ["games", "ru_services"],
    domain_suffix: ["steampowered.com"]
  }
];
for (let i = 2; i <= 50; i++) {
  conditions.push({
    ".name": "cond_Direct_Games_RU_copy" + i,
    ".type": "condition",
    enabled: "1",
    name: "Игры и РФ напрямую Rules",
    condition_type: "atomic",
    type: "atomic",
    community_lists: ["games", "ru_services"],
    domain_suffix: ["steampowered.com"]
  });
}

const fixture50 = {
  settings: {
    ".name": "settings",
    ".type": "settings",
    config_version: "1.0.5",
    proxy_mode: "tproxy",
    applied_migrations: appliedMigrations
  },
  section: [
    {
      ".name": "Direct_Games_RU",
      ".type": "section",
      enabled: "1",
      name: "Игры и РФ напрямую",
      action: "bypass",
      condition_refs: ["cond_Direct_Games_RU_copy50", "cond_Direct_Games_RU_copy12"]
    },
    {
      ".name": "Direct_Games_DNS",
      ".type": "section",
      enabled: "1",
      name: "Игры DNS",
      action: "dns",
      condition_refs: ["cond_Direct_Games_RU_copy2"]
    }
  ],
  condition: conditions
};

const alreadyClean = {
  settings: {
    ".name": "settings",
    ".type": "settings",
    config_version: "1.0.5",
    proxy_mode: "tproxy",
    tun_interface: "tun0",
    tun_inet4: "172.19.0.1/30",
    tun_mtu: "9000",
    engine: "tachyon-core",
    applied_migrations: appliedMigrations
  },
  section: [
    {
      ".name": "CleanSec",
      ".type": "section",
      enabled: "1",
      name: "Clean",
      action: "bypass",
      condition_refs: ["cond_CleanSec"]
    }
  ],
  condition: [
    {
      ".name": "cond_CleanSec",
      ".type": "condition",
      enabled: "1",
      name: "Clean Rules",
      condition_type: "atomic",
      type: "atomic",
      domain_suffix: ["example.org"]
    }
  ]
};

fs.writeFileSync(outPath, JSON.stringify(fixture50, null, 2));
fs.writeFileSync(cleanPath, JSON.stringify(alreadyClean, null, 2));
' "$FIXTURE_IN" "$FIXTURE_ALREADY_CLEAN"

ucode -L "$TACHYON_LIB" "$MIGRATION_UC" migrate-fixture "$FIXTURE_IN" tachyon >"$OUT1"

node -e '
const fs = require("fs");
const assert = require("assert");
const out1 = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const cleanOutPath = process.argv[2];

assert.strictEqual(out1.changed, true, "expected first migration pass to change config");
const conds = (out1.config && out1.config.condition) || [];
assert.strictEqual(conds.length, 1, "expected 50 clones collapsed to 1 canonical condition, got " + conds.length);
assert.strictEqual(conds[0][".name"], "cond_Direct_Games_RU", "expected canonical cond_Direct_Games_RU");

const sections = (out1.config && out1.config.section) || [];
const secByName = Object.fromEntries(sections.map((s) => [s[".name"], s]));
assert.deepStrictEqual(
  secByName.Direct_Games_RU.condition_refs,
  ["cond_Direct_Games_RU"],
  "expected Direct_Games_RU condition_refs length 1 pointing to cond_Direct_Games_RU"
);
assert.deepStrictEqual(
  secByName.Direct_Games_DNS.condition_refs,
  ["cond_Direct_Games_RU"],
  "expected Direct_Games_DNS condition_refs pointing to cond_Direct_Games_RU"
);

fs.writeFileSync(cleanOutPath, JSON.stringify(out1.config, null, 2));
' "$OUT1" "$FIXTURE_CLEAN"

ucode -L "$TACHYON_LIB" "$MIGRATION_UC" migrate-fixture "$FIXTURE_CLEAN" tachyon >"$OUT2"

node -e '
const fs = require("fs");
const assert = require("assert");
const out2 = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
assert.strictEqual(out2.changed, false, "expected second migration pass to return changed: false");
assert.strictEqual(((out2.config && out2.config.condition) || []).length, 1, "expected 1 condition after second pass");
' "$OUT2"

ucode -L "$TACHYON_LIB" "$MIGRATION_UC" migrate-fixture "$FIXTURE_ALREADY_CLEAN" tachyon >"$OUT_ALREADY_CLEAN"

node -e '
const fs = require("fs");
const assert = require("assert");
const outClean = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
assert.strictEqual(outClean.changed, false, "expected clean config with no duplicates to produce changed: false");
assert.strictEqual((outClean.operations || []).length, 0, "expected 0 migration operations on clean config");
assert.strictEqual(((outClean.config && outClean.config.condition) || []).length, 1, "expected 1 condition preserved on clean config");
' "$OUT_ALREADY_CLEAN"

echo "PASS: section_condition_duplication"
