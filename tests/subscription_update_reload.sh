#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

UPDATES_UC="$ROOT_DIR/tachyon/files/usr/lib/components/updates.uc"
REAL_LIB="$ROOT_DIR/tachyon/files/usr/lib"

write_stub() {
  local path="$1"
  local body="$2"

  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$body" >"$path"
}

stub_header='#!/usr/bin/env ucode
let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function shell_quote(value) {
    return "'"'"'" + replace(as_string(value), /'"'"'/g, "'"'"'\\'"'"''"'"'") + "'"'"'";
}

function record(line) {
    let path = getenv("FAKE_CALL_LOG") || "";
    if (path != "")
        system("printf '"'"'%s\\n'"'"' " + shell_quote(line) + " >> " + shell_quote(path));
}
'

FAKE_LIB="$WORK_DIR/lib"

write_stub "$FAKE_LIB/subscription/cache.uc" "$stub_header"'
let mode = as_string(ARGV[0]);
record("subscription/cache:" + mode);
if (mode == "ensure-runtime-dirs")
    exit(0);
if (mode == "update-request") {
    print(getenv("FAKE_SUBSCRIPTION_UPDATE_SUMMARY") || "1 0 0 0", "\n");
    exit(0);
}
exit(64);
'

write_stub "$FAKE_LIB/service/state.uc" "$stub_header"'
let mode = as_string(ARGV[0]);
record("service/state:" + mode);
if (mode == "sing-box-service-runtime-pid") {
    print("3285\n");
    exit(0);
}
if (mode == "sighup-sing-box-runtime") {
    // By default, simulate a successful SIGHUP reload. Tests that need
    // a failing SIGHUP set FAKE_SIGHUP_FAILS=1.
    exit((getenv("FAKE_SIGHUP_FAILS") == "1") ? 1 : 0);
}
if (mode == "acquire-runtime-dir-lock" ||
    mode == "acquire-runtime-dir-lock-wait" ||
    mode == "release-runtime-dir-lock" ||
    mode == "reload-sing-box-runtime" ||
    mode == "write-current-reload-state-clean" ||
    mode == "run-pending-reload-if-requested")
    exit(0);
exit(64);
'

write_stub "$FAKE_LIB/server/service.uc" "$stub_header"'
record("server/service:" + as_string(ARGV[0]));
exit(ARGV[0] == "prepare-all-defaults" ? 0 : 64);
'

write_stub "$FAKE_LIB/config/validator.uc" "$stub_header"'
record("config/validator:" + as_string(ARGV[0]));
exit(ARGV[0] == "validate-runtime" ? 0 : 64);
'

write_stub "$FAKE_LIB/singbox/runtime.uc" "$stub_header"'
let mode = as_string(ARGV[0]);
if (mode == "init-config")
    record("singbox/runtime:init-config:" + as_string(ARGV[1]) + ":" + as_string(ARGV[2]) + ":" + as_string(ARGV[3]));
else
    record("singbox/runtime:" + mode);
if (mode == "configure-service" || mode == "init-config")
    exit(0);
exit(64);
'

write_stub "$FAKE_LIB/singbox/priority.uc" "$stub_header"'
let mode = as_string(ARGV[0]);
record("singbox/priority:" + mode);
if (mode == "stop-runtime" || mode == "start-runtime")
    exit(0);
exit(64);
'

write_stub "$FAKE_LIB/singbox/dns_failover.uc" "$stub_header"'
let mode = as_string(ARGV[0]);
record("singbox/dns_failover:" + mode);
if (mode == "stop-runtime" || mode == "start-runtime")
    exit(0);
exit(64);
'

run_update() {
  local summary="$1"
  local log="$2"

  : >"$log"
  env \
    TACHYON_LIB="$FAKE_LIB" \
    TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/run" \
    TACHYON_SUBSCRIPTION_UPDATE_LOCK_DIR="$WORK_DIR/run/subscription-update.lock" \
    TACHYON_RELOAD_LOCK_DIR="$WORK_DIR/run/reload.lock" \
    TACHYON_SUBSCRIPTION_UPDATE_STATE_DIR="$WORK_DIR/run/subscription-update" \
    TACHYON_SUBSCRIPTION_UPDATE_JOB_DIR="$WORK_DIR/run/subscription-update-jobs" \
    TACHYON_SUBSCRIPTION_LINKS_DIR="$WORK_DIR/run/subscription-links" \
    TACHYON_SUBSCRIPTION_METADATA_DIR="$WORK_DIR/run/subscription-metadata" \
    TACHYON_OUTBOUND_METADATA_DIR="$WORK_DIR/run/outbound-metadata" \
    TACHYON_SECTION_CACHE_DIR="$WORK_DIR/run/section-cache" \
    TACHYON_RUNTIME_CACHE_FORMAT_FILE="$WORK_DIR/run/cache-format" \
    TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/persistent/subscription-cache" \
    TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE="$WORK_DIR/persistent/subscription-cache/cache-format" \
    TACHYON_PENDING_RELOAD_FILE="$WORK_DIR/run/reload.pending" \
    TACHYON_RELOAD_STATE_FILE="$WORK_DIR/run/reload-state" \
    TACHYON_RULE_CONDITION_CACHE_DIR="$WORK_DIR/run/rule-condition-cache" \
    FAKE_CALL_LOG="$log" \
    FAKE_SUBSCRIPTION_UPDATE_SUMMARY="$summary" \
    ucode -L "$REAL_LIB" "$UPDATES_UC" subscription-update-if-due
}

updated_log="$WORK_DIR/updated.log"
run_update "1 0 0 0" "$updated_log"

node - "$updated_log" <<'JS'
const fs = require("fs");
const calls = fs.readFileSync(process.argv[2], "utf8").trim().split(/\n+/);

// Happy path: SIGHUP succeeds, so reload-sing-box-runtime is NOT called.
// Neither helper worker is stopped before it: DNS failover probes the sing-box
// DNS listener, which stays bound across an in-place reload, and Priority's
// start-runtime stops its previous worker by itself (issue #119).
const expected = [
  "subscription/cache:update-request",
  "server/service:prepare-all-defaults",
  "config/validator:validate-runtime",
  "singbox/runtime:configure-service",
  "service/state:sing-box-service-runtime-pid",
  "singbox/runtime:init-config:0:1:1",
  "service/state:sighup-sing-box-runtime",
  "singbox/priority:start-runtime",
  "service/state:write-current-reload-state-clean",
  "service/state:run-pending-reload-if-requested"
];

let position = -1;
for (const item of expected) {
  const next = calls.indexOf(item, position + 1);
  if (next === -1) {
    console.error(`missing or out-of-order call: ${item}`);
    console.error(calls.join("\n"));
    process.exit(1);
  }
  position = next;
}

// reload-sing-box-runtime must NOT be called when SIGHUP succeeds.
if (calls.includes("service/state:reload-sing-box-runtime")) {
  console.error("reload-sing-box-runtime must not be called when SIGHUP reload succeeds");
  process.exit(1);
}

// An ordered "expected" list does not catch extra calls - it only requires the
// listed ones to appear in order. DNS failover is the one that must be absent
// entirely: it is the churn the graceful path removed.
const dns_failover_calls = calls.filter((c) => c.startsWith("singbox/dns_failover:"));
if (dns_failover_calls.length > 0) {
  console.error("DNS failover must not be cycled on the graceful path, got:");
  console.error(dns_failover_calls.join("\n"));
  process.exit(1);
}
JS

# --- SIGHUP-fails fallback test ---
sighup_fail_log="$WORK_DIR/sighup_fail.log"
FAKE_SIGHUP_FAILS=1 \
  env \
    TACHYON_LIB="$FAKE_LIB" \
    TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/run" \
    TACHYON_SUBSCRIPTION_UPDATE_LOCK_DIR="$WORK_DIR/run/subscription-update.lock" \
    TACHYON_RELOAD_LOCK_DIR="$WORK_DIR/run/reload.lock" \
    TACHYON_SUBSCRIPTION_UPDATE_STATE_DIR="$WORK_DIR/run/subscription-update" \
    TACHYON_SUBSCRIPTION_UPDATE_JOB_DIR="$WORK_DIR/run/subscription-update-jobs" \
    TACHYON_SUBSCRIPTION_LINKS_DIR="$WORK_DIR/run/subscription-links" \
    TACHYON_SUBSCRIPTION_METADATA_DIR="$WORK_DIR/run/subscription-metadata" \
    TACHYON_OUTBOUND_METADATA_DIR="$WORK_DIR/run/outbound-metadata" \
    TACHYON_SECTION_CACHE_DIR="$WORK_DIR/run/section-cache" \
    TACHYON_RUNTIME_CACHE_FORMAT_FILE="$WORK_DIR/run/cache-format" \
    TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/persistent/subscription-cache" \
    TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE="$WORK_DIR/persistent/subscription-cache/cache-format" \
    TACHYON_PENDING_RELOAD_FILE="$WORK_DIR/run/reload.pending" \
    TACHYON_RELOAD_STATE_FILE="$WORK_DIR/run/reload-state" \
    TACHYON_RULE_CONDITION_CACHE_DIR="$WORK_DIR/run/rule-condition-cache" \
    FAKE_CALL_LOG="$sighup_fail_log" \
    FAKE_SUBSCRIPTION_UPDATE_SUMMARY="1 0 0 0" \
    ucode -L "$REAL_LIB" "$UPDATES_UC" subscription-update-if-due

# When SIGHUP fails, reload_sing_box_runtime must be called as the fallback.
grep -Fq 'service/state:sighup-sing-box-runtime' "$sighup_fail_log" ||
  fail "sighup-sing-box-runtime must be attempted even when FAKE_SIGHUP_FAILS=1"
grep -Fq 'service/state:reload-sing-box-runtime' "$sighup_fail_log" ||
  fail "reload-sing-box-runtime (restart fallback) must be called when SIGHUP fails"

# The escalation is the one path where a real restart tears down the listeners
# both workers probe, so they have to stand down and come back - and the order
# matters: nothing may be probing while the process it probes through is gone.
node - "$sighup_fail_log" <<'JS'
const fs = require("fs");
const calls = fs.readFileSync(process.argv[2], "utf8").trim().split(/\n+/);

const fallback = [
  "service/state:sighup-sing-box-runtime",
  "singbox/priority:stop-runtime",
  "singbox/dns_failover:stop-runtime",
  "service/state:reload-sing-box-runtime",
  "singbox/dns_failover:start-runtime",
  "singbox/priority:start-runtime",
];

let position = -1;
for (const item of fallback) {
  const next = calls.indexOf(item, position + 1);
  if (next === -1) {
    console.error(`missing or out-of-order call in the SIGHUP fallback: ${item}`);
    console.error(calls.join("\n"));
    process.exit(1);
  }
  position = next;
}
JS

unchanged_log="$WORK_DIR/unchanged.log"
run_update "0 0 1 0" "$unchanged_log"

if grep -Eq 'server/service|config/validator|singbox/runtime|singbox/priority|singbox/dns_failover|reload-sing-box-runtime|write-current-reload-state-clean' "$unchanged_log"; then
  fail "unchanged subscription update must not rebuild or reload sing-box"
fi

printf 'subscription update reload checks passed\n'
