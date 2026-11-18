#!/usr/bin/env bash
# Issue #440 & #431 nft/quarantine checks:
#   1. persist_validator_quarantine() clears stale validator keys from
#      section-errors.json (preserving non-validator keys or removing the file).
#   2. validator.uc accepts excluded_domains / excluded_domains_text tokens
#      (full:, domain:, keyword:, regex:, and plain domain suffixes).
#   3. lifecycle.uc start_impl() and stop_main() clear stale section-errors.json
#      and validator-quarantined.json (honouring TACHYON_* env overrides).
#   4. lifecycle.uc start_main() and reload() resync nft_rebuild_runtime() and
#      nft_populate_runtime_sets() when core_init_config() changes quarantined sections.
#   5. nft/apply.uc nft_populate_runtime_sets_from_uci() dynamic rebuild does not
#      crash on shadowed `common` module.
#   6. nft/apply.uc treats `list community_subnets 'youtube'` as enabled instead of
#      false, and skips nft priority drop for block sections with excluded_domains.
#   7. config/rule.uc legacy_condition_csv_value() falls back to list_value when
#      conditions_text_mode='1' and text_value is empty (keeping text_mode='1' precedence).
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

VALIDATOR_UC="$TACHYON_LIB/config/validator.uc"
LIFECYCLE_UC="$TACHYON_LIB/service/lifecycle.uc"
NFT_APPLY_UC="$TACHYON_LIB/nft/apply.uc"
RULE_UC="$TACHYON_LIB/config/rule.uc"

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run"
export TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/run"
export TACHYON_VALIDATOR_QUARANTINED_FILE="$WORK_DIR/run/validator-quarantined.json"
export TACHYON_SECTION_ERRORS_FILE="$WORK_DIR/run/section-errors.json"
export TACHYON_SECTION_FAIL_STATE_FILE="$WORK_DIR/run/section-fail-state.json"

LOGGER_LOG="$WORK_DIR/logger.log"
NFT_LOG="$WORK_DIR/nft.log"
IP_LOG="$WORK_DIR/ip.log"
export LOGGER_LOG NFT_LOG IP_LOG

cat >"$WORK_DIR/bin/logger" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${LOGGER_LOG:?}"
SH

cat >"$WORK_DIR/bin/ip" <<'SH'
#!/usr/bin/env bash
printf 'ip' >> "${IP_LOG:?}"
for arg in "$@"; do
  printf '\t%s' "$arg" >> "${IP_LOG:?}"
done
printf '\n' >> "${IP_LOG:?}"
if [ "$1" = "route" ] && [ "$2" = "list" ]; then
  printf '%s\n' "${IP_ROUTE_OUTPUT:-}"
fi
if [ "$1" = "-6" ] && [ "$2" = "route" ]; then
  printf '%s\n' "${IP_ROUTE6_OUTPUT:-}"
fi
exit 0
SH

cat >"$WORK_DIR/bin/lsmod" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${LSMOD_OUTPUT:-}"
SH

cat >"$WORK_DIR/bin/sysctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat >"$WORK_DIR/bin/nft" <<'SH'
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
    printf '%s\n' "$line" >> "${NFT_LOG:?}"
  done < "$2"
  rm -f "${NFT_MISSING_MARKER:-/nonexistent}"
fi

if [ "$#" -eq 4 ] && [ "$1" = "list" ] && [ "$2" = "table" ] && [ "$3" = "inet" ]; then
  if [ -n "${NFT_MISSING_MARKER:-}" ] && [ -f "$NFT_MISSING_MARKER" ]; then
    exit 1
  fi
fi
exit 0
SH

chmod 0755 "$WORK_DIR/bin/logger" "$WORK_DIR/bin/ip" "$WORK_DIR/bin/lsmod" "$WORK_DIR/bin/sysctl" "$WORK_DIR/bin/nft"
export PATH="$WORK_DIR/bin:$PATH"

# ─── 1. persist_validator_quarantine() clears stale validator keys ────────────
cat >"$WORK_DIR/val_bad.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ]
  },
  "section": [
    {
      ".name": "good_sec",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [ "socks5://127.0.0.1:1081#Good" ]
    },
    {
      ".name": "bad_sec",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "ports": [ "99999" ]
    }
  ]
}
JSON

cat >"$WORK_DIR/val_fixed.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ]
  },
  "section": [
    {
      ".name": "good_sec",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [ "socks5://127.0.0.1:1081#Good" ]
    },
    {
      ".name": "bad_sec",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "ports": [ "443" ],
      "selector_proxy_links": [ "socks5://127.0.0.1:1082#Fixed" ]
    },
    {
      ".name": "blk_sec",
      ".type": "section",
      "enabled": "1",
      "action": "block",
      "community_lists": [ "ads_hagezi_pro" ],
      "excluded_domains": [ "full:metrika.yandex.ru", "domain:ads.example", "keyword:tracker", "regex:^ad\\.", "plain.example" ],
      "excluded_domains_text": "full:one.example\ndomain:two.example\nthree.example"
    }
  ]
}
JSON

rm -f "$TACHYON_VALIDATOR_QUARANTINED_FILE" "$TACHYON_SECTION_ERRORS_FILE"
ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-quarantine-fixture "$WORK_DIR/val_bad.json" >/dev/null
[ -f "$TACHYON_VALIDATOR_QUARANTINED_FILE" ] || fail "validator must create validator-quarantined.json"
[ -f "$TACHYON_SECTION_ERRORS_FILE" ] || fail "validator must create section-errors.json"
grep -Fq '"bad_sec":' "$TACHYON_SECTION_ERRORS_FILE" || fail "bad_sec must appear in section-errors.json"

# Simulate an unrelated core error alongside bad_sec; fixing bad_sec must drop
# bad_sec while keeping core_sec.
ucode -e '
  let fs = require("fs");
  let p = getenv("TACHYON_SECTION_ERRORS_FILE");
  let d = json(fs.readfile(p));
  d.core_sec = "core check failed";
  fs.writefile(p, sprintf("%J\n", d));
'
: >"$LOGGER_LOG"
ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-quarantine-fixture "$WORK_DIR/val_fixed.json" >/dev/null
[ ! -e "$TACHYON_VALIDATOR_QUARANTINED_FILE" ] || fail "validator-quarantined.json must be removed when no validator errors remain"
[ -f "$TACHYON_SECTION_ERRORS_FILE" ] || fail "section-errors.json must remain when core_sec error is still present"
if grep -Fq '"bad_sec":' "$TACHYON_SECTION_ERRORS_FILE"; then
  fail "stale validator key bad_sec must be cleared from section-errors.json"
fi
grep -Fq '"core_sec":' "$TACHYON_SECTION_ERRORS_FILE" || fail "non-validator core_sec error must be preserved"
if grep -Fq "Ignoring invalid domain condition" "$LOGGER_LOG"; then
  fail "valid excluded_domains tokens (including domain:) must not emit invalid domain warnings: $(cat "$LOGGER_LOG")"
fi

# When only stale validator keys existed and validation passes, section-errors.json must be removed.
rm -f "$TACHYON_VALIDATOR_QUARANTINED_FILE" "$TACHYON_SECTION_ERRORS_FILE"
ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-quarantine-fixture "$WORK_DIR/val_bad.json" >/dev/null
[ -f "$TACHYON_SECTION_ERRORS_FILE" ] || fail "section-errors.json must exist before clean re-validation"
ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-quarantine-fixture "$WORK_DIR/val_fixed.json" >/dev/null
[ ! -e "$TACHYON_SECTION_ERRORS_FILE" ] || fail "section-errors.json must be removed when all errors are cleared"

# Verify nft priority_rules honors section-errors.json for quarantined fail_policy sections
cat >"$WORK_DIR/prio_fixture.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    {
      ".name": "sec_direct",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "fail_policy": "direct",
      "ip_cidr": [ "198.51.100.0/24" ]
    },
    {
      ".name": "sec_block",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "fail_policy": "block",
      "ip_cidr": [ "203.0.113.0/24" ]
    }
  ]
}
JSON
printf '{"sec_direct":"core failed","sec_block":"core failed"}\n' >"$TACHYON_SECTION_ERRORS_FILE"
: >"$NFT_LOG"
ucode -L "$TACHYON_LIB" "$NFT_APPLY_UC" nft-add-section-priority-rules-fixture \
  "$WORK_DIR/prio_fixture.json" TachyonTable tachyon_interfaces localv4 localv6 0x04000000
grep -F 'tachyon_rule_sec_direct_subnets' "$NFT_LOG" | grep -Fq 'accept' ||
  fail "quarantined fail_policy=direct must emit accept in priority_rules"
if grep -F 'tachyon_rule_sec_direct_subnets' "$NFT_LOG" | grep -Fq '0x04000000'; then
  fail "quarantined fail_policy=direct must not emit meta mark set"
fi
grep -F 'tachyon_rule_sec_block_subnets' "$NFT_LOG" | grep -Fq 'drop' ||
  fail "quarantined fail_policy=block must emit drop in priority_rules"

rm -f "$TACHYON_SECTION_ERRORS_FILE"
: >"$NFT_LOG"
ucode -L "$TACHYON_LIB" "$NFT_APPLY_UC" nft-add-section-priority-rules-fixture \
  "$WORK_DIR/prio_fixture.json" TachyonTable tachyon_interfaces localv4 localv6 0x04000000
grep -F 'tachyon_rule_sec_direct_subnets' "$NFT_LOG" | grep -Fq '0x04000000' ||
  fail "cleared fail_policy=direct must emit meta mark set 0x04000000 in priority_rules"
grep -F 'tachyon_rule_sec_block_subnets' "$NFT_LOG" | grep -Fq '0x04000000' ||
  fail "cleared fail_policy=block must emit meta mark set 0x04000000 in priority_rules"

# ─── 2. lifecycle.uc start_impl / stop_main cleanup & quarantine resync ──────
sed '/^let mode =/,$d' "$LIFECYCLE_UC" >"$WORK_DIR/lifecycle_harness.uc"
cat >>"$WORK_DIR/lifecycle_harness.uc" <<'UC'
let calls = [];
let sim_core_action = null;
let sim_plan_rebuild = "0";

log_message = function(message, level) {};
external_config_fingerprint = function() { return "fp"; };
current_config_hash = function() { return "h1"; };
last_completed_reload_hash = function() { return "h0"; };
validate_start_config = function() { return 0; };
module_status = function(mod, args) {
    if (mod == STATE_UC && type(args) == "array" && args[0] == "write-captured-reload-state")
        return 0;
    return 0;
};
module_success = function(mod, args) {
    if (mod == STATE_UC && type(args) == "array" && args[0] == "tachyon-running")
        return true;
    return true;
};
module_background = function(mod, args) {};
module_output = function(mod, args) { return ""; };
module_capture = function(mod, args) {
    if (mod == RELOAD_UC && type(args) == "array" && args[0] == "plan-state-files") {
        let out = "changed_service_triggers\t0\nchanged_tachyon_core\t1\nchanged_nft\t" + sim_plan_rebuild +
            "\nneeds_tachyon_core_reload\t1\nneeds_nft_rebuild\t" + sim_plan_rebuild + "\nhas_work\t1\n";
        return { status: 0, output: out };
    }
    return { status: 0, output: "" };
};
restore_rulesets_from_cache = function() {};
prepare_community_rulesets = function() {};
acquire_start_subscription_update_lock = function() { return true; };
release_start_subscription_update_lock = function() {};
refresh_cron = function() { return 0; };
remove_cron_jobs = function() {};
restore_selector_state = function(s) {};
sync_selector_defaults_after_reload = function(s) {};
write_service_trigger_sync_state = function(c) {};
finish_reload_status = function(st, fp) { return st; };
config_get = function(key, fallback) { return fallback || ""; };
file_md5 = function(p) { return "md5"; };
dnsmasq_has_tachyon_managed_state = function() { return false; };
command_status = function(cmd) { return 0; };
command_success_from_args = function(args) { return true; };
command_output_from_args = function(args) {
    if (type(args) == "array" && args[0] == "ubus")
        return "{\"instances\":{}}";
    if (type(args) == "array" && args[0] == "mktemp") {
        let tmp = getenv("WORK_DIR") + "/tmp-reload-state";
        fs.writefile(tmp, "");
        return tmp;
    }
    return "";
};
kill_switch = {
    hold: function() { return ""; },
    release_if_ready: function() {},
    stop_hold: function() { return ""; },
    remove: function() {},
    release: function() {}
};
purge_legacy_steer_runtime = function() {};

nft_rebuild_runtime = function() {
    let err = as_string(fs.readfile(SECTION_ERRORS_FILE) || "");
    push(calls, "rebuild:" + trim(err));
    return 0;
};
nft_populate_runtime_sets = function() {
    push(calls, "populate:" + as_string(nft_populate_enabled));
    return 0;
};
core_init_config = function() {
    push(calls, "core_init");
    if (sim_core_action)
        sim_core_action();
    return 0;
};

// Test 2a: stop_main() clears section-errors.json and validator-quarantined.json
fs.writefile(SECTION_ERRORS_FILE, "{\"stale\":\"err\"}\n");
fs.writefile(VALIDATOR_QUARANTINED_FILE, "{\"stale\":\"err\"}\n");
stop_main();
if (fs.stat(SECTION_ERRORS_FILE) != null || fs.stat(VALIDATOR_QUARANTINED_FILE) != null)
    die("stop_main must clear section-errors.json and validator-quarantined.json\n");

// Test 2b: start_impl() clears stale section-fail-state, section-errors, validator-quarantined before start_main
let saved_start_main = start_main;
start_main = function() {
    if (fs.stat(SECTION_FAIL_STATE_FILE) != null ||
        fs.stat(SECTION_ERRORS_FILE) != null ||
        fs.stat(VALIDATOR_QUARANTINED_FILE) != null)
        die("start_impl must clear stale quarantine files before start_main\n");
    return 1;
};
fs.writefile(SECTION_FAIL_STATE_FILE, "{\"s\":{\"failed\":true}}\n");
fs.writefile(SECTION_ERRORS_FILE, "{\"stale\":\"err\"}\n");
fs.writefile(VALIDATOR_QUARANTINED_FILE, "{\"stale\":\"err\"}\n");
start_impl();
start_main = saved_start_main;

// Test 2c: start_main() resyncs nft when core_init_config() adds a quarantined section
calls = [];
remove_file(SECTION_ERRORS_FILE);
sim_core_action = function() {
    fs.writefile(SECTION_ERRORS_FILE, "{\"sec_bad\":\"core failed\"}\n");
};
if (start_main() != 0)
    die("start_main failed in quarantine resync test\n");
if (calls[0] != "rebuild:" || calls[1] != "core_init" ||
    index(calls[2] || "", "rebuild:{\"sec_bad\":\"core failed\"}") != 0 ||
    calls[3] != "populate:1")
    die("start_main must re-run nft_rebuild_runtime and nft_populate_runtime_sets when core_init_config adds quarantine; got " + sprintf("%J", calls) + "\n");

// Test 2d: start_main() does NOT redundantly rebuild when quarantine did not change
calls = [];
sim_core_action = function() {};
if (start_main() != 0)
    die("start_main failed in unchanged quarantine test\n");
if (length(calls) != 2 || calls[0] != "rebuild:{\"sec_bad\":\"core failed\"}" || calls[1] != "core_init")
    die("start_main must not rebuild nft twice when quarantine is unchanged; got " + sprintf("%J", calls) + "\n");

// Test 2e: start_main() resyncs nft when core_init_config() clears a previously quarantined section
calls = [];
sim_core_action = function() {
    remove_file(SECTION_ERRORS_FILE);
};
if (start_main() != 0)
    die("start_main failed in quarantine clear test\n");
if (calls[0] != "rebuild:{\"sec_bad\":\"core failed\"}" || calls[1] != "core_init" ||
    calls[2] != "rebuild:" || calls[3] != "populate:1")
    die("start_main must resync nft when core_init_config clears quarantine; got " + sprintf("%J", calls) + "\n");

// Test 2f: reload("force") with needs_nft_rebuild=0 still rebuilds & populates nft when core_init_config changes quarantine
calls = [];
remove_file(SECTION_ERRORS_FILE);
sim_plan_rebuild = "0";
sim_core_action = function() {
    fs.writefile(SECTION_ERRORS_FILE, "{\"sec_reload\":\"core failed\"}\n");
};
if (reload("force") != 0)
    die("reload failed in needs_nft_rebuild=0 quarantine resync test\n");
if (calls[0] != "core_init" ||
    index(calls[1] || "", "rebuild:{\"sec_reload\":\"core failed\"}") != 0 ||
    calls[2] != "populate:1")
    die("reload must rebuild and populate nft when core_init_config changes quarantine even if needs_nft_rebuild=0; got " + sprintf("%J", calls) + "\n");

// Test 2g: reload("force") with needs_nft_rebuild=1 rebuilds & populates again if core_init_config clears quarantine
calls = [];
sim_plan_rebuild = "1";
sim_core_action = function() {
    remove_file(SECTION_ERRORS_FILE);
};
if (reload("force") != 0)
    die("reload failed in needs_nft_rebuild=1 quarantine clear test\n");
if (index(calls[0] || "", "rebuild:{\"sec_reload\":\"core failed\"}") != 0 ||
    calls[1] != "core_init" ||
    calls[2] != "rebuild:" ||
    calls[3] != "populate:1")
    die("reload must resync nft after core_init_config clears quarantine; got " + sprintf("%J", calls) + "\n");
UC
WORK_DIR="$WORK_DIR" ucode -L "$TACHYON_LIB" "$WORK_DIR/lifecycle_harness.uc" ||
  fail "lifecycle quarantine cleanup/resync harness failed"

# ─── 3. nft_populate_runtime_sets_from_uci dynamic rebuild (no common shadow) ─
cat >"$WORK_DIR/uci_dyn.state" <<'EOF_UCI'
tachyon.settings=settings
tachyon.settings.source_network_interfaces=br-lan
tachyon.settings.ipv6_mode=auto
tachyon.sec1=section
tachyon.sec1.enabled=1
tachyon.sec1.action=connection
tachyon.sec1.ip_cidr=198.51.100.0/24
EOF_UCI
: >"$NFT_LOG"
touch "$WORK_DIR/nft_missing"
TACHYON_UCI_STATE_FILE="$WORK_DIR/uci_dyn.state" \
NFT_MISSING_MARKER="$WORK_DIR/nft_missing" \
  ucode -L "$TACHYON_LIB" "$NFT_APPLY_UC" nft-populate-runtime-sets-from-uci \
    1 "" TachyonTable tachyon_subnets tachyon_ports tachyon_ip_ports tachyon_interfaces localv4 0x04000000 ||
  fail "nft_populate_runtime_sets_from_uci dynamic rebuild must succeed without crashing on shadowed common"
grep -Fq $'198.51.100.0/24' "$NFT_LOG" ||
  fail "dynamic rebuild must populate section subnets afterwards"

# ─── 4. list community_subnets 'youtube' & excluded_domains block filter ──────
printf '198.51.100.0/24\n' >"$WORK_DIR/discord-subnets.lst"
cat >"$WORK_DIR/comm_fixture.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    {
      ".name": "yt_comm",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "community_lists": [ "discord" ],
      "community_subnets": [ "youtube" ]
    },
    {
      ".name": "comm_off",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "community_lists": [ "discord" ],
      "community_subnets": "0"
    }
  ]
}
JSON

: >"$NFT_LOG"
ucode -L "$TACHYON_LIB" "$NFT_APPLY_UC" nft-add-community-subnet-file-for-section-fixture \
  "$WORK_DIR/comm_fixture.json" yt_comm discord "$WORK_DIR/discord-subnets.lst" \
  TachyonTable tachyon_subnets tachyon_ip_ports tachyon_interfaces tachyon_discord 0x04000000 5000 ||
  fail "community subnet loading fixture failed"
grep -Fq '198.51.100.0/24' "$NFT_LOG" ||
  fail "list community_subnets 'youtube' must not disable community subnet loading"

: >"$NFT_LOG"
ucode -L "$TACHYON_LIB" "$NFT_APPLY_UC" nft-add-community-subnet-file-for-section-fixture \
  "$WORK_DIR/comm_fixture.json" comm_off discord "$WORK_DIR/discord-subnets.lst" \
  TachyonTable tachyon_subnets tachyon_ip_ports tachyon_interfaces tachyon_discord 0x04000000 5000 ||
  fail "disabled community_subnets fixture failed"
if grep -Fq '198.51.100.0/24' "$NFT_LOG"; then
  fail "explicit community_subnets=0 must still disable community subnet loading"
fi

# Block section with excluded_domains must skip nftables priority_rules drop
cat >"$WORK_DIR/block_excl.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    {
      ".name": "blk_plain",
      ".type": "section",
      "enabled": "1",
      "action": "block",
      "ip_cidr": [ "198.51.100.0/24" ]
    },
    {
      ".name": "blk_excl",
      ".type": "section",
      "enabled": "1",
      "action": "block",
      "ip_cidr": [ "203.0.113.0/24" ],
      "excluded_domains": [ "full:metrika.yandex.ru" ]
    }
  ]
}
JSON

sig_plain="$(ucode -L "$TACHYON_LIB" "$NFT_APPLY_UC" nft-runtime-signature-fixture "$WORK_DIR/block_excl.json")"
cat >"$WORK_DIR/block_excl_2.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    {
      ".name": "blk_plain",
      ".type": "section",
      "enabled": "1",
      "action": "block",
      "ip_cidr": [ "198.51.100.0/24" ]
    },
    {
      ".name": "blk_excl",
      ".type": "section",
      "enabled": "1",
      "action": "block",
      "ip_cidr": [ "203.0.113.0/24" ],
      "excluded_domains": [ "full:other.yandex.ru" ]
    }
  ]
}
JSON
sig_changed="$(ucode -L "$TACHYON_LIB" "$NFT_APPLY_UC" nft-runtime-signature-fixture "$WORK_DIR/block_excl_2.json")"
[ "$sig_plain" != "$sig_changed" ] || fail "changing excluded_domains must change nft runtime signature"

: >"$NFT_LOG"
ucode -L "$TACHYON_LIB" "$NFT_APPLY_UC" nft-add-section-priority-rules-fixture \
  "$WORK_DIR/block_excl.json" TachyonTable tachyon_interfaces localv4 localv6 0x04000000
grep -F 'tachyon_rule_blk_plain_subnets' "$NFT_LOG" | grep -Fq 'drop' ||
  fail "plain block section must emit drop in nft priority_rules"
grep -F 'tachyon_rule_blk_excl_subnets' "$NFT_LOG" | grep -Fq '0x04000000' ||
  fail "block section with excluded_domains must capture to tachyon-core instead of dropping in nft"
if grep -F 'tachyon_rule_blk_excl_subnets' "$NFT_LOG" | grep -Eq 'drop|reject'; then
  fail "block section with excluded_domains must not emit drop/reject directly in nft"
fi

# ─── 5. config/rule.uc legacy_condition_csv_value conditions_text_mode fallback
res_fallback="$(ucode -L "$TACHYON_LIB" -e '
  let r = require("config.rule");
  print(r.legacy_condition_csv_value("subnets", "0", "1", "", "198.51.100.0/24"));
')"
[ "$res_fallback" = "198.51.100.0/24" ] ||
  fail "conditions_text_mode=1 with empty text_value and text_mode=0 must fall back to list_value, got '$res_fallback'"

res_explicit="$(ucode -L "$TACHYON_LIB" -e '
  let r = require("config.rule");
  print(r.legacy_condition_csv_value("subnets", "1", "1", "", "198.51.100.0/24"));
')"
[ -z "$res_explicit" ] ||
  fail "field-level text_mode=1 with empty text_value must stay empty, got '$res_explicit'"

res_nonempty="$(ucode -L "$TACHYON_LIB" -e '
  let r = require("config.rule");
  print(r.legacy_condition_csv_value("subnets", "0", "1", "203.0.113.0/24", "198.51.100.0/24"));
')"
[ "$res_nonempty" = "203.0.113.0/24" ] ||
  fail "conditions_text_mode=1 with non-empty text_value must prefer text_value, got '$res_nonempty'"

printf 'issue_440_quarantine_ip_mark: OK\n'
