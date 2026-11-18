#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

RELOAD_UC="$TACHYON_LIB/service/reload.uc"
LIFECYCLE_UC="$TACHYON_LIB/service/lifecycle.uc"
WATCHDOG_UC="$TACHYON_LIB/service/watchdog.uc"
DOCTOR_UC="$TACHYON_LIB/diagnostics/doctor.uc"
DIAG_RUNTIME_UC="$TACHYON_LIB/diagnostics/runtime.uc"

FAKE_BIN="$WORK_DIR/bin"
FAKE_LIB="$WORK_DIR/fake-lib"
RUN_DIR="$WORK_DIR/run"
TMP_RULESETS="$WORK_DIR/tmp-rulesets"
ETC_RULESETS="$WORK_DIR/etc-rulesets"
mkdir -p "$FAKE_BIN" "$FAKE_LIB" "$RUN_DIR" "$TMP_RULESETS" "$ETC_RULESETS"
cp -r "$TACHYON_LIB"/. "$FAKE_LIB"/

write_state() {
  local path="$1"
  cat >"$path" <<'EOF'
format=1
service_trigger_signature=sig
dnsmasq_signature=dns
tachyon_core_signature=core
nft_signature=nft
list_signature=list
hosts_list_signature=hosts
cron_signature=cron
dont_touch_dhcp=0
enabled_urltest_sections=Main
EOF
}

# 1. force_runtime_reload=1 in reload.uc must force BOTH tachyon_core_reload and nft_rebuild
write_state "$WORK_DIR/prev.state"
write_state "$WORK_DIR/curr.state"
plan="$(ucode -L "$TACHYON_LIB" "$RELOAD_UC" plan-state-files "$WORK_DIR/prev.state" "$WORK_DIR/curr.state" 1 0 0 0 0)"
printf '%s\n' "$plan" | grep -Eq '^needs_tachyon_core_reload[[:space:]]+1$' ||
  fail "force_runtime_reload=1 must set needs_tachyon_core_reload=1 (got: $plan)"
printf '%s\n' "$plan" | grep -Eq '^needs_nft_rebuild[[:space:]]+1$' ||
  fail "force_runtime_reload=1 must set needs_nft_rebuild=1 so dns_redirect rules rebuild (got: $plan)"

# 2. Explicit lifecycle.uc reload (reason="") must NOT skip on matching config hash,
#    while background on_config_change still skips on matching hash.
CFG_FILE="$WORK_DIR/tachyon.config"
printf "config settings 'settings'\n\toption enabled '1'\n" >"$CFG_FILE"
RELOAD_HASH_FILE="$WORK_DIR/reload.hash"
md5sum "$CFG_FILE" | awk '{print $1}' >"$RELOAD_HASH_FILE"
cp "$WORK_DIR/prev.state" "$RUN_DIR/reload-state"

stub_header='#!/usr/bin/env ucode
let fs = require("fs");
function as_string(v) { return v == null ? "" : "" + v; }
function record(line) {
    let p = getenv("FAKE_CALL_LOG") || "";
    if (p != "") {
        let f = fs.open(p, "a");
        if (f) { f.write(as_string(line) + "\n"); f.close(); }
    }
}
'
mkdir -p "$FAKE_LIB/config" "$FAKE_LIB/dns"
cat >"$FAKE_LIB/config/validator.uc" <<'EOF'
#!/usr/bin/env ucode
exit(0);
EOF
mkdir -p "$FAKE_LIB/server"
cat >"$FAKE_LIB/server/service.uc" <<'EOF'
#!/usr/bin/env ucode
exit(0);
EOF
CORE_BIN="$FAKE_BIN/tachyon-core"
cat >"$CORE_BIN" <<'SH'
#!/usr/bin/env sh
if [ "$1" = "version" ]; then
  echo "tachyon-core version 0.5.9"
  exit 0
fi
if [ "$1" = "check" ] && [ "$2" = "-c" ]; then
  node - "$3" <<'NODE'
const fs = require('fs');
const cfg = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
for (const rs of ((cfg.route && cfg.route.rule_set) || [])) {
  if (rs.type === 'local' && (!fs.existsSync(rs.path) || rs.path.endsWith('.srs'))) {
    console.error(`open ${rs.path}: no such file or directory`);
    process.exit(1);
  }
}
process.exit(0);
NODE
  exit $?
fi
exit 0
SH
chmod +x "$CORE_BIN"
cat >"$FAKE_LIB/subscription/cache.uc" <<EOF
$stub_header
if ((ARGV[0] || "") == "runtime-cache-needs-rebuild")
    exit(1);
exit(0);
EOF
cat >"$FAKE_LIB/service/state.uc" <<EOF
$stub_header
let mode = as_string(ARGV[0]);
record("state:" + mode);
if (mode == "capture-reload-state") {
    let f = fs.open(ARGV[1], "w");
    if (f) { f.write("{}"); f.close(); }
    exit(0);
}
if (mode == "write-captured-reload-state") {
    let dst = ARGV[1];
    let f = fs.open(dst, "w");
    if (f) {
        f.write("format=1\nservice_trigger_signature=sig\ndnsmasq_signature=dns\ntachyon_core_signature=core\nnft_signature=nft\nlist_signature=list\nhosts_list_signature=hosts\ncron_signature=cron\ndont_touch_dhcp=0\nenabled_urltest_sections=Main\n");
        f.close();
    }
    exit(0);
}
exit(0);
EOF
cp "$TACHYON_LIB/service/reload.uc" "$FAKE_LIB/service/reload.uc"
cat >"$FAKE_LIB/service/ui.uc" <<EOF
$stub_header
if (ARGV[0] == "service-action-begin-if-idle") { print("\n"); }
exit(0);
EOF
cat >"$FAKE_LIB/service/dns_failover.uc" <<EOF
$stub_header
exit(0);
EOF
cat >"$FAKE_LIB/service/parental_quota.uc" <<EOF
$stub_header
exit(0);
EOF
cat >"$FAKE_LIB/dns/apply.uc" <<EOF
$stub_header
exit(1);
EOF
mkdir -p "$FAKE_LIB/dns"
cat >"$FAKE_LIB/nft/apply.uc" <<EOF
$stub_header
record("nft:" + as_string(ARGV[0]));
exit(0);
EOF
cat >"$FAKE_LIB/tachyon_core/priority.uc" <<EOF
$stub_header
exit(0);
EOF
cat >"$FAKE_LIB/tachyon_core/dns_failover.uc" <<EOF
$stub_header
exit(0);
EOF
cat >"$FAKE_LIB/tachyon_core/runtime.uc" <<EOF
$stub_header
record("core_runtime:" + as_string(ARGV[0]));
exit(0);
EOF

cat >"$WORK_DIR/uci.state" <<EOF
tachyon.settings=settings
tachyon.settings.enabled=1
tachyon.settings.dont_touch_dhcp=1
tachyon.settings.ipv6_mode=on
tachyon.settings.fakeip_enabled=1
tachyon.settings.dns_strategy=prefer_ipv4
tachyon.settings.fakeip_inet6_range=fd42::/48
tachyon.settings.config_path=$WORK_DIR/core-config.json
tachyon.Main=section
tachyon.Main.enabled=1
tachyon.Main.action=connection
tachyon.Main.community_lists=ru_whitelist
tachyon.Main.outbound_jsons={"type":"direct","tag":"direct-out"}
EOF

RELOAD_LOG="$WORK_DIR/reload.log"
: > "$RELOAD_LOG"
env PATH="$FAKE_BIN:$PATH" \
  TACHYON_LIB="$FAKE_LIB" \
  TACHYON_CONFIG_FILE="$CFG_FILE" \
  TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state" \
  TACHYON_RUNTIME_STATE_DIR="$RUN_DIR" \
  TACHYON_RELOAD_STATE_FILE="$RUN_DIR/reload-state" \
  TACHYON_RELOAD_HASH_FILE="$RELOAD_HASH_FILE" \
  TACHYON_RELOAD_LOCK_DIR="$WORK_DIR/reload.lock" \
  TACHYON_PERSISTENT_RULESETS_DIR="$ETC_RULESETS" \
  TMP_RULESET_FOLDER="$TMP_RULESETS" \
  FAKE_CALL_LOG="$RELOAD_LOG" \
  ucode -L "$FAKE_LIB" -L "$TACHYON_LIB" "$LIFECYCLE_UC" reload on_config_change >/dev/null 2>&1 || true

if grep -Fq 'nft:nft-rebuild-runtime-from-uci' "$RELOAD_LOG"; then
  fail "background on_config_change reload should still skip when config hash matches"
fi

: > "$RELOAD_LOG"
reload_err="$(env PATH="$FAKE_BIN:$PATH" \
  TACHYON_LIB="$FAKE_LIB" \
  TACHYON_CONFIG_FILE="$CFG_FILE" \
  TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state" \
  TACHYON_RUNTIME_STATE_DIR="$RUN_DIR" \
  TACHYON_RELOAD_STATE_FILE="$RUN_DIR/reload-state" \
  TACHYON_RELOAD_HASH_FILE="$RELOAD_HASH_FILE" \
  TACHYON_RELOAD_LOCK_DIR="$WORK_DIR/reload.lock" \
  TACHYON_PERSISTENT_RULESETS_DIR="$ETC_RULESETS" \
  TMP_RULESET_FOLDER="$TMP_RULESETS" \
  FAKE_CALL_LOG="$RELOAD_LOG" \
  ucode -L "$FAKE_LIB" -L "$TACHYON_LIB" "$LIFECYCLE_UC" reload "" 2>&1)" ||
  fail "explicit lifecycle reload returned non-zero ($reload_err | log: $(tr '\n' ',' < "$RELOAD_LOG"))"

grep -Fq 'nft:nft-rebuild-runtime-from-uci' "$RELOAD_LOG" ||
  fail "explicit reload must rebuild nftables (dns_redirect / tachyon-dns-intercept) even with matching UCI hash (log: $(tr '\n' ',' < "$RELOAD_LOG"))"
grep -Fq 'core_runtime:configure-service' "$RELOAD_LOG" ||
  fail "explicit reload must refresh tachyon-core runtime"

# 3. Watchdog core_config_ipv6_matches detects FakeIPv6 config drift
cat >"$WORK_DIR/core-config.json" <<'JSON'
{
  "dns": {
    "strategy": "ipv4_only",
    "servers": [
      { "type": "fakeip", "tag": "fakeip-dns", "inet4_range": "198.18.0.0/15" }
    ]
  }
}
JSON

drift="$(TACHYON_LIB="$TACHYON_LIB" TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state" \
  TACHYON_CORE_CONFIG="$WORK_DIR/core-config.json" \
  ucode -L "$TACHYON_LIB" "$WATCHDOG_UC" core-config-ipv6-matches-fixture)"
[ "$drift" = "0" ] || fail "watchdog must report 0 when FakeIPv6 config lacks inet6_range while ipv6_active=true (got '$drift')"

cat >"$WORK_DIR/core-config.json" <<'JSON'
{
  "dns": {
    "strategy": "prefer_ipv4",
    "servers": [
      { "type": "fakeip", "tag": "fakeip-dns", "inet4_range": "198.18.0.0/15", "inet6_range": "fd42::/48" }
    ]
  }
}
JSON

matched="$(TACHYON_LIB="$TACHYON_LIB" TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state" \
  TACHYON_CORE_CONFIG="$WORK_DIR/core-config.json" \
  ucode -L "$TACHYON_LIB" "$WATCHDOG_UC" core-config-ipv6-matches-fixture)"
[ "$matched" = "1" ] || fail "watchdog must report 1 when FakeIPv6 config matches active IPv6 state (got '$matched')"

# 4. doctor --fix repairs invalid config pointing to deleted .srs by regenerating via init-config
acquire_core_proc_lock
CLEANUP_PID=""
cleanup_with_proc() {
  if [ -n "${CLEANUP_PID:-}" ]; then
    kill "$CLEANUP_PID" 2>/dev/null || true
    wait "$CLEANUP_PID" 2>/dev/null || true
  fi
  release_core_proc_lock
  rm -rf "$WORK_DIR"
}
trap cleanup_with_proc EXIT

FAKE_SLEEP_BIN="$WORK_DIR/proc-bin/tachyon-core"
mkdir -p "$WORK_DIR/proc-bin"
cp "$(command -v sleep)" "$FAKE_SLEEP_BIN"
"$FAKE_SLEEP_BIN" 45 &
CLEANUP_PID="$!"

CORE_INIT="$WORK_DIR/init-tachyon-core"
TACHYON_INIT="$WORK_DIR/init-tachyon"
TACHYON_CLI="$WORK_DIR/tachyon-cli"
DOCTOR_EVENTS="$WORK_DIR/doctor-events.log"
: > "$DOCTOR_EVENTS"
cat >"$CORE_INIT" <<EOF
#!/usr/bin/env sh
echo "core-init:\$*" >> "$DOCTOR_EVENTS"
exit 0
EOF
cat >"$TACHYON_INIT" <<EOF
#!/usr/bin/env sh
echo "tachyon-init:\$*" >> "$DOCTOR_EVENTS"
exit 0
EOF
cat >"$TACHYON_CLI" <<EOF
#!/usr/bin/env sh
echo "tachyon-cli:\$*" >> "$DOCTOR_EVENTS"
exit 0
EOF
chmod +x "$CORE_INIT" "$TACHYON_INIT" "$TACHYON_CLI"

cat >"$FAKE_BIN/curl" <<'SH'
#!/usr/bin/env sh
exit 22
SH
cat >"$FAKE_BIN/ip" <<'SH'
#!/usr/bin/env sh
exit 0
SH
cat >"$FAKE_BIN/nft" <<'SH'
#!/usr/bin/env sh
exit 0
SH
cat >"$FAKE_BIN/logread" <<'SH'
#!/usr/bin/env sh
exit 0
SH
cat >"$FAKE_BIN/netstat" <<'SH'
#!/usr/bin/env sh
exit 0
SH
cat >"$FAKE_BIN/ping" <<'SH'
#!/usr/bin/env sh
exit 1
SH
cat >"$FAKE_BIN/dig" <<'SH'
#!/usr/bin/env sh
exit 0
SH
chmod +x "$FAKE_BIN/curl" "$FAKE_BIN/ip" "$FAKE_BIN/nft" "$FAKE_BIN/logread" "$FAKE_BIN/netstat" "$FAKE_BIN/ping" "$FAKE_BIN/dig"

cat >"$WORK_DIR/core-config.json" <<JSON
{
  "route": {
    "rule_set": [
      {
        "type": "local",
        "tag": "Main-ru_whitelist-community-ruleset",
        "format": "binary",
        "path": "$TMP_RULESETS/community-ru_whitelist.srs"
      }
    ]
  }
}
JSON

# Mirror TACHYON_LIB into a test lib dir where only configure-service is stubbed
# (avoiding root-only /etc/init.d/tachyon-core writes on CI) while init-config
# runs the real runtime.uc + generator.uc.
DOC_LIB="$WORK_DIR/doc-lib"
mkdir -p "$DOC_LIB"
cp -r "$TACHYON_LIB"/. "$DOC_LIB"/
cat >"$DOC_LIB/tachyon_core/runtime.uc" <<EOF
#!/usr/bin/env ucode
let common = require("core.common");
if ((ARGV[0] || "") == "configure-service")
    exit(0);
let args = [ "ucode", "-L", "$TACHYON_LIB", "$TACHYON_LIB/tachyon_core/runtime.uc" ];
for (let a in ARGV)
    push(args, a);
exit(common.command_status("TACHYON_LIB=" + common.shell_quote("$TACHYON_LIB") + " " + common.command_from_args(args)));
EOF

DOC_RUN_UC="$DOC_LIB/diagnostics/runtime.uc"
doc_fix_out="$(env PATH="$FAKE_BIN:$PATH" \
  TACHYON_LIB="$DOC_LIB" \
  TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state" \
  TACHYON_CORE_CONFIG="$WORK_DIR/core-config.json" \
  TACHYON_CORE_BIN="$CORE_BIN" \
  TACHYON_CORE_INIT="$CORE_INIT" \
  TACHYON_INIT="$TACHYON_INIT" \
  TACHYON_BIN="$TACHYON_CLI" \
  TMP_RULESET_FOLDER="$TMP_RULESETS" \
  TACHYON_PERSISTENT_RULESETS_DIR="$ETC_RULESETS" \
  TACHYON_RUNTIME_STATE_DIR="$RUN_DIR" \
  TACHYON_SECTION_ERRORS_FILE="$RUN_DIR/section-errors.json" \
  TACHYON_VALIDATOR_QUARANTINED_FILE="$RUN_DIR/validator-quarantined.json" \
  TACHYON_CONFIG_OWNERS_FILE="$RUN_DIR/config-owners.json" \
  TACHYON_DOCTOR_LOCK_DIR="$WORK_DIR/doctor.lock" \
  ucode -L "$DOC_LIB" -L "$TACHYON_LIB" -- "$DOC_RUN_UC" doctor --fix 2>&1)" || true

node - "$doc_fix_out" <<'NODE'
const raw = process.argv[2];
const jsonLine = raw.split(/\r?\n/).reverse().find(l => l.trim().startsWith('{'));
if (!jsonLine) {
  console.error('doctor --fix produced no JSON line:', raw);
  process.exit(1);
}
const doc = JSON.parse(jsonLine);
const line = String(doc.report || '').split('\n').find(l => l.includes('tachyon-core config'));
if (!line || !line.includes('FIXED') || line.includes('не удалось восстановить')) {
  console.error('Unexpected tachyon-core config line:', line);
  process.exit(1);
}
NODE
if grep -Fq '.srs' "$WORK_DIR/core-config.json"; then
  fail "repaired core-config.json still contains .srs path: $(cat "$WORK_DIR/core-config.json")"
fi
grep -Fq 'ru_whitelist.trs' "$WORK_DIR/core-config.json" ||
  fail "repaired core-config.json must switch to native .trs ruleset"

# 5. FakeIPv6 check respects custom fakeip_inet6_range and skips under ipv4_only
cat >"$FAKE_BIN/dig" <<'SH'
#!/usr/bin/env sh
printf '%s\n' "fd42:0:0:1::2"
exit 0
SH
chmod +x "$FAKE_BIN/dig"

cat >"$WORK_DIR/probe_doctor_checks.uc" <<'UC'
let doc = require("diagnostics.doctor");
print(sprintf("%J\n", doc.run_doctor_checks_impl(false)));
UC

doc_v6_json="$(env PATH="$FAKE_BIN:$PATH" \
  TACHYON_LIB="$DOC_LIB" \
  TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state" \
  TACHYON_CORE_CONFIG="$WORK_DIR/core-config.json" \
  TACHYON_CORE_BIN="$CORE_BIN" \
  TACHYON_CORE_INIT="$CORE_INIT" \
  TACHYON_INIT="$TACHYON_INIT" \
  TACHYON_BIN="$TACHYON_CLI" \
  TMP_RULESET_FOLDER="$TMP_RULESETS" \
  TACHYON_PERSISTENT_RULESETS_DIR="$ETC_RULESETS" \
  TACHYON_RUNTIME_STATE_DIR="$RUN_DIR" \
  TACHYON_DOCTOR_LOCK_DIR="$WORK_DIR/doctor.lock" \
  ucode -L "$DOC_LIB" -L "$TACHYON_LIB" "$WORK_DIR/probe_doctor_checks.uc" 2>/dev/null || true)"

node - "$doc_v6_json" <<'NODE'
const doc = JSON.parse(process.argv[2]);
const check = (doc.checks || []).find(c => c.name === 'tachyon-core FakeIPv6');
if (!check || check.status !== 'pass') {
  console.error('Custom fakeip_inet6_range fd42::/48 should pass FakeIPv6 check:', check);
  process.exit(1);
}
NODE

# Switch dig to return empty (failing FakeIPv6) with dns_strategy=ipv4_only -> must NOT warn
cat >"$FAKE_BIN/dig" <<'SH'
#!/usr/bin/env sh
exit 0
SH
chmod +x "$FAKE_BIN/dig"
sed -i 's/tachyon.settings.dns_strategy=prefer_ipv4/tachyon.settings.dns_strategy=ipv4_only/' "$WORK_DIR/uci.state"

doc_v4only_json="$(env PATH="$FAKE_BIN:$PATH" \
  TACHYON_LIB="$DOC_LIB" \
  TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state" \
  TACHYON_CORE_CONFIG="$WORK_DIR/core-config.json" \
  TACHYON_CORE_BIN="$CORE_BIN" \
  TACHYON_CORE_INIT="$CORE_INIT" \
  TACHYON_INIT="$TACHYON_INIT" \
  TACHYON_BIN="$TACHYON_CLI" \
  TMP_RULESET_FOLDER="$TMP_RULESETS" \
  TACHYON_PERSISTENT_RULESETS_DIR="$ETC_RULESETS" \
  TACHYON_RUNTIME_STATE_DIR="$RUN_DIR" \
  TACHYON_DOCTOR_LOCK_DIR="$WORK_DIR/doctor.lock" \
  ucode -L "$DOC_LIB" -L "$TACHYON_LIB" "$WORK_DIR/probe_doctor_checks.uc" 2>/dev/null || true)"

node - "$doc_v4only_json" <<'NODE'
const doc = JSON.parse(process.argv[2]);
const check = (doc.checks || []).find(c => c.name === 'tachyon-core FakeIPv6');
if (check && check.status !== 'pass') {
  console.error('FakeIPv6 check must be skipped under dns_strategy=ipv4_only:', check);
  process.exit(1);
}
NODE

# 6. local_rule_doctor must map FakeIPv6 warning to doctor_fix, and repairs.uc must execute doctor_fix + reload force
cat >"$WORK_DIR/probe_local_doctor.uc" <<'UC'
let doc = require("diagnostics.doctor");
let pre_res = {
    report: "warn",
    issues: 1,
    fixed: 0,
    checks: [
        { name: "tachyon-core FakeIPv6", status: "warn", detail: "AAAA query did not return FakeIPv6 in fc00::/18", fix: "→ WILL FIX (doctor --fix)" }
    ]
};
let pre_verify = {
    checks: [
        { name: "tachyon-core process", status: "pass", detail: "running" },
        { name: "WAN interface", status: "pass", detail: "eth1 up" }
    ],
    failed: 0,
    stability: { wan_flaps: 0, tachyon_core_restarts: 0, dnsmasq_restarts: 0 }
};
let out = doc.local_rule_doctor(pre_res, pre_verify);
print(sprintf("%J\n", out));
UC

local_doc_out="$(env PATH="$FAKE_BIN:$PATH" TACHYON_LIB="$TACHYON_LIB" TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state" \
  ucode -L "$TACHYON_LIB" "$WORK_DIR/probe_local_doctor.uc" 2>/dev/null)"
node - "$local_doc_out" <<'NODE'
const out = JSON.parse(process.argv[2]);
const fixes = String(out.quick_fix || '').split(',').filter(Boolean);
if (!fixes.includes('doctor_fix')) {
  console.error('local_rule_doctor must emit doctor_fix for FakeIPv6 warning:', out);
  process.exit(1);
}
const dnsNode = (out.nodes || []).find(n => n.name === 'DNS');
if (!dnsNode || dnsNode.status === 'OK') {
  console.error('DNS pillar should reflect WARN status on FakeIPv6 warning:', out.nodes);
  process.exit(1);
}
NODE

: > "$DOCTOR_EVENTS"
env PATH="$FAKE_BIN:$PATH" \
  TACHYON_LIB="$TACHYON_LIB" \
  TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state" \
  TACHYON_BIN="$TACHYON_CLI" \
  TACHYON_INIT="$TACHYON_INIT" \
  TACHYON_DOCTOR_FIXES_FILE="$WORK_DIR/fixes.json" \
  ucode -L "$TACHYON_LIB" "$DIAG_RUNTIME_UC" apply-quick-fix "doctor_fix,rebuild_rules" >/dev/null ||
  fail "apply-quick-fix doctor_fix,rebuild_rules failed"

grep -Fq 'tachyon-cli:doctor --fix' "$DOCTOR_EVENTS" ||
  fail "doctor_fix quick action did not run tachyon doctor --fix (events: $(cat "$DOCTOR_EVENTS"))"
grep -Fq 'tachyon-init:reload force' "$DOCTOR_EVENTS" ||
  fail "rebuild_rules quick action did not run init reload force (events: $(cat "$DOCTOR_EVENTS"))"

printf 'reload_ipv6_doctor_sync: all checks passed\n'
