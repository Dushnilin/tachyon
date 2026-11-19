#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

FUZZER_UC="$TACHYON_LIB/diagnostics/fuzzer.uc"

# 1. Verify start_fuzzer passes TACHYON_JOB_HARD_DEADLINE_SECONDS=0 when timeout_seconds=="0"
#    (previously int("0") || 2700 silently reverted to 2700).
START_DIR="$WORK_DIR/start-test"
ST_STATE="$START_DIR/state"
FAKE_BIN="$START_DIR/bin"
FAKE_LIB="$START_DIR/lib"
ENV_LOG="$START_DIR/worker_env.log"
mkdir -p "$ST_STATE" "$FAKE_BIN" "$FAKE_LIB"

cp -r "$TACHYON_LIB"/. "$FAKE_LIB"/
REAL_UCODE="$(command -v ucode)"

cat >"$FAKE_LIB/diagnostics/fuzzer/binaries.uc" <<'UC'
function get_desync_bin() { return "/usr/bin/true"; }
function resolve_target_url() { return "https://example.com"; }
function resolve_target_urls_list() { return [ { url: "https://example.com", required: true } ]; }
function prewarm_targets_dns() {}
function get_timeout_prefix() { return ""; }
function wrap_cmd_timeout(cmd) { return cmd; }
function run_bounded() { return 0; }
function target_scope_match() { return ""; }
function probe_target_ips() { return []; }
function add_bypass_core_chain() { return true; }
function cleanup_bypass_core_chain() { return true; }
return {
    TARGET_SUITES: {},
    get_desync_bin,
    resolve_target_url,
    resolve_target_urls_list,
    prewarm_targets_dns,
    get_timeout_prefix,
    wrap_cmd_timeout,
    run_bounded,
    target_scope_match,
    probe_target_ips,
    add_bypass_core_chain,
    cleanup_bypass_core_chain
};
UC

cat >"$FAKE_BIN/ucode" <<EOF
#!/usr/bin/env sh
printf '%s\n' "\${TACHYON_JOB_HARD_DEADLINE_SECONDS:-UNSET}" > "$ENV_LOG"
exit 0
EOF
chmod +x "$FAKE_BIN/ucode"

: > "$ENV_LOG"
out_start="$(env PATH="$FAKE_BIN:$PATH" \
  TACHYON_LIB="$FAKE_LIB" \
  TACHYON_FUZZER_STATE_DIR="$ST_STATE" \
  "$REAL_UCODE" -L "$FAKE_LIB" -- "$FAKE_LIB/diagnostics/fuzzer.uc" start desync youtube "" "" "" presets 0)"

case "$out_start" in
  *'"success": true'*|*'"success":true'*) ;;
  *) fail "start_fuzzer with timeout=0 failed: $out_start" ;;
esac

# Background shell subcommand writes $ENV_LOG asynchronously; wait briefly
waited=0
while [ ! -s "$ENV_LOG" ] && [ "$waited" -lt 30 ]; do
  sleep 0.1
  waited=$((waited + 1))
done

got_deadline="$(tr -d '\r\n' < "$ENV_LOG")"
[ "$got_deadline" = "0" ] ||
  fail "start_fuzzer(..., timeout=0) must launch worker with TACHYON_JOB_HARD_DEADLINE_SECONDS=0, got '$got_deadline'"

# 2. Verify worker loop with TACHYON_JOB_HARD_DEADLINE_SECONDS=0 completes all strategies
#    even when elapsed > 0 seconds, while positive deadline still stops early.
W_DIR="$WORK_DIR/worker-test"
W_STATE="$W_DIR/state"
W_LIB="$W_DIR/lib"
mkdir -p "$W_STATE" "$W_LIB/diagnostics/fuzzer"
cp -r "$TACHYON_LIB"/. "$W_LIB"/

cat >"$W_LIB/diagnostics/fuzzer/binaries.uc" <<'UC'
function get_desync_bin() { return "/usr/bin/true"; }
function resolve_target_url() { return "https://example.com"; }
function resolve_target_urls_list() { return [ { url: "https://example.com", required: true } ]; }
function prewarm_targets_dns() {}
function get_timeout_prefix(sec) { return ""; }
function wrap_cmd_timeout(cmd, sec, pid_file) { return cmd; }
function run_bounded(cmd, sec) { return 0; }
function target_scope_match(ips) { return ""; }
function probe_target_ips(target, custom_url) { return []; }
function add_bypass_core_chain() { return true; }
function cleanup_bypass_core_chain() { return true; }
return {
    TARGET_SUITES: {},
    get_desync_bin,
    resolve_target_url,
    resolve_target_urls_list,
    prewarm_targets_dns,
    get_timeout_prefix,
    wrap_cmd_timeout,
    run_bounded,
    target_scope_match,
    probe_target_ips,
    add_bypass_core_chain,
    cleanup_bypass_core_chain
};
UC

cat >"$W_LIB/diagnostics/fuzzer/targets.uc" <<'UC'
function resolve_target_url(target, custom_url) { return "https://example.com"; }
function check_direct_baseline(target, custom_url, job_id) {
    return { accessible: false, direct_ok: false, baseline: {}, dpi_type: "tls_rst" };
}
function detect_dpi_type(target, custom_url) { return { detected: true, dpi_type: "tls_rst" }; }
function rerank_strategies_by_dpi(strategies, dpi_type) { return strategies; }
return {
    TARGET_SUITES: {},
    TARGET_URLS: {},
    resolve_target_url,
    check_direct_baseline,
    detect_dpi_type,
    rerank_strategies_by_dpi
};
UC

cat >"$W_LIB/diagnostics/fuzzer/strategies.uc" <<'UC'
let list = [
    { id: "s1", name: "Strategy 1", engine: "desync", args: "--mode=fake --fake-ttl=5" },
    { id: "s2", name: "Strategy 2", engine: "desync", args: "--mode=multisplit --split-pos=midsld" }
];
return {
    get_strategies_for_engine: function() { return list; },
    rerank_strategies_by_dpi: function(s) { return s; },
    get_presets_info: function() { return {}; },
    update_presets: function() { return true; },
    get_patterns_config: function() { return {}; },
    save_patterns_config: function() { return true; },
    reset_patterns_config: function() { return true; }
};
UC

cat >"$W_LIB/diagnostics/fuzzer/probe.uc" <<'UC'
let common = require("core.common");
let seen_first = false;
function cleanup_temp_daemons() {}
function run_probe(engine, args, target, custom_url, job_id, probe_opts) {
    if (!seen_first) {
        seen_first = true;
        common.command_status("sleep 2");
    }
    return {
        success: true,
        http_code: 200,
        handshake_ms: 20,
        ttfb_ms: 40,
        speed_kbps: 1024,
        data_bytes: 65536,
        data_verified: true,
        dpi_verdict: "verified_256k",
        score: 900,
        error: "",
        passed_endpoints: 1,
        total_endpoints: 1,
        sub_probes: []
    };
}
return {
    DESYNC_PORT: 11090,
    JOB_HARD_DEADLINE_SECONDS: 0,
    kill_pid_file: function() {},
    cleanup_temp_daemons,
    parse_curl_output: function() { return {}; },
    run_probe
};
UC

cat >"$W_LIB/diagnostics/fuzzer_runner.uc" <<'UC'
return {
    validate_strategy_args: function() { return true; },
    parse_desync_outbound: function(a, tag) { return { type: "desync", tag: tag }; },
    validate_custom_targets_input: function() { return { valid: true, urls: ["https://example.com"] }; },
    get_system_memory_kb: function() { return 65536; },
    calculate_median: function(arr) { return length(arr) > 0 ? arr[0] : 0; },
    calculate_p25: function(arr) { return length(arr) > 0 ? arr[0] : 0; },
    calculate_jitter: function() { return 0; }
};
UC

cat >"$W_LIB/diagnostics/fuzzer/history.uc" <<'UC'
let fs = require("fs");
let common = require("core.common");
const STATE_DIR = getenv("TACHYON_FUZZER_STATE_DIR") || "/var/run/tachyon";
const STATE_FILE = STATE_DIR + "/fuzzer-state.json";
const PID_FILE = STATE_DIR + "/fuzzer-worker.pid";
const JOBS_DIR = STATE_DIR + "/fuzzer";
const HISTORY_FILE = STATE_DIR + "/history.json";
function ensure_state_dir() { common.ensure_dir(STATE_DIR); common.ensure_dir(JOBS_DIR); }
function get_job_dir(id) { return JOBS_DIR + "/" + id; }
function ensure_job_dir(id) { let d = get_job_dir(id); common.ensure_dir(d); return d; }
function load_history() { return { entries: [] }; }
function save_history() { return true; }
function append_history() { return true; }
function get_history() { return []; }
function clear_history() {}
function get_fuzzer_state() { return common.read_json_file(STATE_FILE) || { running: false, results: [] }; }
function save_fuzzer_state(st) { common.write_json_file(STATE_FILE, st); }
function is_job_aborted() { return false; }
function set_job_aborted() {}
return {
    STATE_DIR, STATE_FILE, PID_FILE, JOBS_DIR, HISTORY_FILE,
    ensure_state_dir, get_job_dir, ensure_job_dir,
    load_history, save_history, append_history, get_history, clear_history,
    get_fuzzer_state, save_fuzzer_state, is_job_aborted, set_job_aborted
};
UC

# Unlimited (0): elapsed becomes >= 2s after Strategy 1, Strategy 2 must STILL run!
TACHYON_FUZZER_STATE_DIR="$W_STATE" \
TACHYON_JOB_HARD_DEADLINE_SECONDS=0 \
  ucode -L "$W_LIB" -- "$W_LIB/diagnostics/fuzzer.uc" worker desync youtube "" "" "" presets fuzz_unlim ||
  fail "fuzzer worker with TACHYON_JOB_HARD_DEADLINE_SECONDS=0 failed"

node - "$W_STATE/fuzzer-state.json" <<'NODE'
const fs = require('fs');
const st = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (st.running !== false) {
  console.error('FAIL: worker state still running:', st);
  process.exit(1);
}
if (st.error) {
  console.error('FAIL: unlimited timeout must NOT trigger hard deadline error:', st.error);
  process.exit(1);
}
if (!Array.isArray(st.results) || st.results.length !== 2) {
  console.error('FAIL: expected all 2 strategies to complete under unlimited timeout, got:', st.results && st.results.length);
  process.exit(1);
}
NODE

# Positive deadline (1): elapsed becomes >= 2s after Strategy 1, so Strategy 2 must stop at hard deadline!
rm -f "$W_STATE/fuzzer-state.json"
TACHYON_FUZZER_STATE_DIR="$W_STATE" \
TACHYON_JOB_HARD_DEADLINE_SECONDS=1 \
  ucode -L "$W_LIB" -- "$W_LIB/diagnostics/fuzzer.uc" worker desync youtube "" "" "" presets fuzz_lim ||
  fail "fuzzer worker with TACHYON_JOB_HARD_DEADLINE_SECONDS=1 failed"

node - "$W_STATE/fuzzer-state.json" <<'NODE'
const fs = require('fs');
const st = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (!st.error || !String(st.error).includes('Hard deadline reached')) {
  console.error('FAIL: expected positive 1s deadline to stop at Hard deadline reached, got:', st);
  process.exit(1);
}
NODE

# Sanity check parsing variants on production file directly via grep/ucode -c
ucode -c -o /dev/null "$FUZZER_UC"
echo "fuzzer_unlimited_timeout: all checks passed"
