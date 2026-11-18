#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

MIGRATION_UC="$TACHYON_LIB/config/migration.uc"
GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"
STATE_UC="$TACHYON_LIB/service/state.uc"

# --- 1. Migration clears legacy invalid tcp_profile values and preserves valid ones ---
cat >"$WORK_DIR/mig_legacy.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_version": "1.8.0",
    "tcp_profile": "low_latency"
  }
}
JSON
ucode -L "$TACHYON_LIB" "$MIGRATION_UC" migrate-fixture "$WORK_DIR/mig_legacy.json" >"$WORK_DIR/mig_legacy.out"
ucode -e '
let fs = require("fs");
let data = json(fs.readfile(ARGV[0]));
if (!data.changed) exit(1);
if (data.config.settings.tcp_profile != null) exit(2);
' "$WORK_DIR/mig_legacy.out" || fail "migration must clear legacy low_latency tcp_profile"

for legacy_val in throughput conservative none bogus; do
  cat >"$WORK_DIR/mig_${legacy_val}.json" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_version": "1.8.0",
    "tcp_profile": "${legacy_val}"
  }
}
JSON
  ucode -L "$TACHYON_LIB" "$MIGRATION_UC" migrate-fixture "$WORK_DIR/mig_${legacy_val}.json" >"$WORK_DIR/mig_${legacy_val}.out"
  ucode -e '
let fs = require("fs");
let data = json(fs.readfile(ARGV[0]));
if (data.config.settings.tcp_profile != null) exit(1);
' "$WORK_DIR/mig_${legacy_val}.out" || fail "migration must clear invalid tcp_profile=$legacy_val"
done

for valid_val in auto windows macos ios android linux; do
  cat >"$WORK_DIR/mig_${valid_val}.json" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_version": "1.8.0",
    "tcp_profile": "${valid_val}"
  }
}
JSON
  ucode -L "$TACHYON_LIB" "$MIGRATION_UC" migrate-fixture "$WORK_DIR/mig_${valid_val}.json" >"$WORK_DIR/mig_${valid_val}.out"
  ucode -e '
let fs = require("fs");
let data = json(fs.readfile(ARGV[0]));
if (data.config.settings.tcp_profile != ARGV[1]) exit(1);
' "$WORK_DIR/mig_${valid_val}.out" "$valid_val" || fail "migration must preserve valid tcp_profile=$valid_val"
done

# --- 2. Generator never puts tcp_profile under route and drops unmigrated values ---
make_gen_fixture() {
  local out_file="$1"
  local prof="$2"
  cat >"$out_file" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1",
    "tcp_profile": "${prof}"
  },
  "section": [
    {
      ".name": "sec_proxy",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [
        "vless://00000000-0000-4000-8000-000000000001@proxy.example.com:443#NodeA",
        "vless://00000000-0000-4000-8000-000000000002@proxy2.example.com:443#NodeB"
      ],
      "domain_suffix": [ "example.com" ]
    },
    {
      ".name": "sec_desync",
      ".type": "section",
      "enabled": "1",
      "action": "desync",
      "desync_preset": "auto",
      "domain_suffix": [ "video.example.org" ]
    },
    {
      ".name": "sec_block",
      ".type": "section",
      "enabled": "1",
      "action": "block",
      "domain_suffix": [ "ads.example.net" ]
    }
  ]
}
JSON
}

make_gen_fixture "$WORK_DIR/gen_legacy.json" "low_latency"
TACHYON_CORE_VERSION_OVERRIDE="0.5.9" ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture "$WORK_DIR/gen_legacy.json" "$WORK_DIR/gen_legacy.cfg" "127.0.0.1" "0" "1" >/dev/null
ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));
if (cfg.route.tcp_profile != null) exit(1);
for (let ob in cfg.outbounds) {
  if (ob.tcp_profile != null) exit(2);
}
' "$WORK_DIR/gen_legacy.cfg" || fail "unmigrated low_latency must not emit route.tcp_profile or outbound tcp_profile"

for prof in auto windows; do
  make_gen_fixture "$WORK_DIR/gen_${prof}.json" "$prof"
  TACHYON_CORE_VERSION_OVERRIDE="0.5.9" ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture "$WORK_DIR/gen_${prof}.json" "$WORK_DIR/gen_${prof}.cfg" "127.0.0.1" "0" "1" >/dev/null
  ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));
let want = ARGV[1];
if (cfg.route.tcp_profile != null) { warn("route.tcp_profile must not be set\n"); exit(1); }
let seen_dial = 0;
let seen_desync = 0;
for (let ob in cfg.outbounds) {
  if (ob.type == "direct" || ob.type == "selector" || ob.type == "urltest" || ob.type == "block") {
    if (ob.tcp_profile != null) { warn("non-dial outbound got tcp_profile: " + ob.type + "\n"); exit(2); }
  } else if (ob.type == "vless" || ob.type == "desync") {
    if (ob.tcp_profile != want) { warn("outbound missing tcp_profile " + want + " on " + ob.type + "\n"); exit(3); }
    seen_dial++;
    if (ob.type == "desync") seen_desync++;
  }
}
if (seen_dial < 2 || seen_desync < 1) { warn("missing expected outbounds\n"); exit(4); }
for (let ep in (cfg.endpoints || [])) {
  if (ep.tcp_profile != want) { warn("endpoint missing tcp_profile\n"); exit(5); }
}
' "$WORK_DIR/gen_${prof}.cfg" "$prof" || fail "generator tcp_profile propagation failed for $prof"
done

# --- 3. service/state.uc signature detects settings.tcp_profile transitions ---
cat >"$WORK_DIR/sig_default.json" <<'JSON'
{ "settings": { ".name": "settings", ".type": "settings", "enabled": "1" }, "section": [], "server": [] }
JSON
cat >"$WORK_DIR/sig_auto.json" <<'JSON'
{ "settings": { ".name": "settings", ".type": "settings", "enabled": "1", "tcp_profile": "auto" }, "section": [], "server": [] }
JSON
sig1="$(ucode -L "$TACHYON_LIB" "$STATE_UC" tachyon-core-signature-fixture "$WORK_DIR/sig_default.json")"
sig2="$(ucode -L "$TACHYON_LIB" "$STATE_UC" tachyon-core-signature-fixture "$WORK_DIR/sig_auto.json")"
[ "$sig1" != "$sig2" ] || fail "tachyon_core_signature must change when settings.tcp_profile changes"

printf 'tcp_profile tachyon-core checks passed\n'
