#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

FUZZER="$ROOT_DIR/tachyon/files/usr/lib/diagnostics/fuzzer.uc"
TACHYON_BIN="$ROOT_DIR/tachyon/files/usr/bin/tachyon"

# 1. Check strategies JSON output
strategies_json="$(ucode -L "$TACHYON_LIB" -- "$FUZZER" strategies)"
[ -n "$strategies_json" ] || fail "fuzzer strategies returned empty output"

# Validate JSON structure using node: desync only, no removed engines
JSON_VALUE="$strategies_json" node <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
if (typeof val.available_engines !== 'object' || val.available_engines.desync == null) {
  console.error("Missing available_engines.desync:", val.available_engines);
  process.exit(1);
}
for (const oldEng of ['zapret2', 'zapret', 'byedpi']) {
  if (Object.prototype.hasOwnProperty.call(val.available_engines, oldEng) ||
      Object.prototype.hasOwnProperty.call(val, oldEng)) {
    console.error(`Removed engine ${oldEng} leaked into strategies response`);
    process.exit(1);
  }
}
if (!Array.isArray(val.desync) || val.desync.length === 0) {
  console.error("Missing desync strategies");
  process.exit(1);
}
NODE

# 2. Check each desync strategy passes desync validator and parser
desync_args="$(JSON_VALUE="$strategies_json" node - <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
for (const s of val.desync) {
  console.log(s.args);
}
NODE
)"

while IFS= read -r args; do
  [ -n "$args" ] || continue
  TACHYON_LIB="$TACHYON_LIB" ARG_STR="$args" ucode -L "$TACHYON_LIB" - <<'UCODE'
let r = require("diagnostics.fuzzer_runner");
let s = getenv("ARG_STR");
if (!r.validate_strategy_args("desync", s)) {
    warn("Desync strategy failed validate_strategy_args: " + s + "\n");
    exit(1);
}
let ob = r.parse_desync_outbound(s, "ds-test");
if (!ob || ob.type != "desync") {
    warn("Desync strategy failed parse_desync_outbound: " + s + "\n");
    exit(1);
}
UCODE
done <<< "$desync_args"

# 3. Check status returns clean default state
status_json="$(ucode -L "$TACHYON_LIB" -- "$FUZZER" status)"
JSON_VALUE="$status_json" node <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
if (val.running !== false) {
  console.error("Default fuzzer status should have running: false");
  process.exit(1);
}
if (!Array.isArray(val.results)) {
  console.error("Results should be an array");
  process.exit(1);
}
NODE

# 4. Check tachyon CLI command map contains fuzzer commands
grep -q 'fuzzer_start:' "$TACHYON_BIN" || fail "tachyon CLI missing fuzzer_start"
grep -q 'fuzzer_status:' "$TACHYON_BIN" || fail "tachyon CLI missing fuzzer_status"
grep -q 'fuzzer_stop:' "$TACHYON_BIN" || fail "tachyon CLI missing fuzzer_stop"
grep -q 'fuzzer_apply:' "$TACHYON_BIN" || fail "tachyon CLI missing fuzzer_apply"
grep -q 'fuzzer_strategies:' "$TACHYON_BIN" || fail "tachyon CLI missing fuzzer_strategies"
grep -q 'fuzzer_generate:' "$TACHYON_BIN" || fail "tachyon CLI missing fuzzer_generate"
grep -q 'fuzzer_ai_synthesize:' "$TACHYON_BIN" || fail "tachyon CLI missing fuzzer_ai_synthesize"

# 5. Check combinatorial strategies generation
combo_tmp="$(mktemp "${TMPDIR:-/tmp}/fuzzer_combo_XXXXXX")"
trap 'rm -f "$combo_tmp"' EXIT
ucode -L "$TACHYON_LIB" -- "$FUZZER" strategies combinatorial > "$combo_tmp"
COMBO_FILE="$combo_tmp" node <<'NODE'
const fs = require('fs');
const raw = fs.readFileSync(process.env.COMBO_FILE, 'utf8');
const val = JSON.parse(raw);
if (!Array.isArray(val.desync) || val.desync.length < 30) {
  console.error("Combinatorial desync should have >= 30 strategies, got:", val.desync ? val.desync.length : 0);
  process.exit(1);
}
console.log("Generated matrix: Desync=" + val.desync.length);
NODE

# 6. Check hardcoded runner, fail-closed validation, and absence of global killall curl
grep -q 'killall -9 curl' "$FUZZER" && fail "killall -9 curl must not be present in fuzzer.uc" || true

ucode -L "$TACHYON_LIB" -e '
let r = require("diagnostics.fuzzer_runner");
let probe = require("diagnostics.fuzzer.probe");

// 1. Fail-closed: unknown/removed/empty engines rejected by runner validator
for (let bad_eng in ["", "unknown_engine", "zapret2", "zapret", "byedpi"]) {
    if (r.validate_strategy_args(bad_eng, "preset=auto") !== false) {
        warn("Failed: non-desync engine was not rejected: " + bad_eng + "\n");
        exit(1);
    }
}

// 2. Fail-closed: shell metacharacters rejected
if (r.validate_strategy_args("desync", "split_pos=1; rm -rf /") !== false) {
    warn("Failed: semicolon command injection was not rejected\n");
    exit(1);
}
if (r.validate_strategy_args("desync", "mode=split | reboot") !== false) {
    warn("Failed: pipe command injection was not rejected\n");
    exit(1);
}
if (r.validate_strategy_args("desync", "mode=split `reboot`") !== false) {
    warn("Failed: backtick command injection was not rejected\n");
    exit(1);
}
if (r.validate_strategy_args("desync", "split_pos=$(cat /etc/passwd)") !== false) {
    warn("Failed: command substitution was not rejected\n");
    exit(1);
}
if (r.validate_strategy_args("desync", "preset=auto") !== true) {
    warn("Failed: desync preset=auto should validate\n");
    exit(1);
}

// HTTP 421 probe parsing and scoring
let res421 = probe.parse_curl_output("421\t0.120\t2.450\t128\t156\t0.040\t1\t0", {});
if (!res421.success || res421.ttfb_ms != 120 || res421.score < 1000) {
    warn(sprintf("unexpected 421 parse result: %J\n", res421));
    exit(1);
}

// 3. Hostname and URL validation
if (!r.is_valid_hostname("youtube.com") || !r.is_valid_hostname("googlevideo.com") || !r.is_valid_hostname("1.1.1.1")) {
    warn("Failed: valid hostname was rejected\n");
    exit(1);
}
if (r.is_valid_hostname("evil.com;rm") || r.is_valid_hostname("evil.com`id`") || r.is_valid_hostname("")) {
    warn("Failed: malicious hostname was accepted\n");
    exit(1);
}
if (!r.is_valid_url("https://www.youtube.com/watch?v=dQw4w9WgXcQ")) {
    warn("Failed: valid URL was rejected\n");
    exit(1);
}
if (r.is_valid_url("http://evil.com/`rm -rf /`") || r.is_valid_url("https://evil.com/;reboot") || r.is_valid_url("")) {
    warn("Failed: malicious URL was accepted\n");
    exit(1);
}

// 4. Tokenizer limit checks
let huge = "";
for (let i = 0; i < 70; i++) huge += sprintf("--split-pos=%d ", i);
let tok = r.tokenize_strategy_args(huge);
if (tok.valid !== false) {
    warn("Failed: token limit > 64 was not rejected\n");
    exit(1);
}

// 5. System capabilities & stats calculation checks
let caps = r.get_system_capabilities();
if (type(caps) != "object" || type(caps.http2) != "bool" || type(caps.http3) != "bool") {
    warn("Failed: invalid capabilities object returned\n");
    exit(1);
}

let mem_kb = r.get_system_memory_kb();
if (type(mem_kb) != "int" || mem_kb <= 0) {
    warn("Failed: invalid memory returned\n");
    exit(1);
}

let test_vals = [ 100, 110, 120 ];
let med = r.calculate_median(test_vals);
if (med != 110) {
    warn(sprintf("Failed: median should be 110, got %d\n", med));
    exit(1);
}

let jitter = r.calculate_jitter(test_vals, med);
if (jitter != 6 && jitter != 7) {
    warn(sprintf("Failed: jitter unexpected, got %d\n", jitter));
    exit(1);
}

let p25 = r.calculate_p25([ 100, 200, 300, 400 ]);
if (p25 != 200 && p25 != 100) {
    warn(sprintf("Failed: p25 unexpected, got %d\n", p25));
    exit(1);
}

print("Hardened runner, capabilities, and statistics checks passed.\n");
'

# 8. Check TARGET_SUITES structure and requirements
ucode -L "$TACHYON_LIB" -- "$FUZZER" strategies presets | JSON_VALUE="$(cat)" node - <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
const suites = val.target_suites;
if (!suites || typeof suites !== 'object') {
  console.error("Missing target_suites");
  process.exit(1);
}

const yt = suites.youtube_suite;
if (!yt || !Array.isArray(yt.urls) || yt.urls.length < 3) {
  console.error("Invalid youtube_suite structure");
  process.exit(1);
}

const streamItem = yt.urls.find(u => u.name && u.name.includes("Stream"));
if (!streamItem || streamItem.required !== true || streamItem.probe_kind !== 'streaming') {
  console.error("YouTube Stream CDN must have required: true and probe_kind: streaming, got:", streamItem);
  process.exit(1);
}

for (const key of Object.keys(suites)) {
  const s = suites[key];
  for (const u of s.urls) {
    if (typeof u.weight !== 'number' || u.weight <= 0) {
      console.error(`Missing valid weight in ${key}:`, u);
      process.exit(1);
    }
    if (typeof u.probe_kind !== 'string') {
      console.error(`Missing probe_kind in ${key}:`, u);
      process.exit(1);
    }
  }
}
console.log("Verified TARGET_SUITES weights, required flags, and probe kinds.");
NODE

# 9. Check Adaptive strategy generation
adaptive_tmp="$(mktemp "${TMPDIR:-/tmp}/fuzzer_adaptive_XXXXXX")"
trap 'rm -f "$adaptive_tmp" "$combo_tmp"' EXIT
ucode -L "$TACHYON_LIB" -- "$FUZZER" strategies adaptive > "$adaptive_tmp"
ADAPTIVE_FILE="$adaptive_tmp" node <<'NODE'
const fs = require('fs');
const val = JSON.parse(fs.readFileSync(process.env.ADAPTIVE_FILE, 'utf8'));
if (!Array.isArray(val.desync) || val.desync.length < 5) {
  console.error("Adaptive desync should have >= 5 strategies, got:", val.desync ? val.desync.length : 0);
  process.exit(1);
}
console.log("Adaptive strategies generated: Desync=" + val.desync.length);
NODE

# 10. Check that apply rejects global provider, removed engines, and requires valid target section
apply_empty="$(ucode -L "$TACHYON_LIB" -- "$FUZZER" apply desync "preset=auto" "" 2>/dev/null || true)"
JSON_VALUE="$apply_empty" node <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
if (val.success !== false) {
  console.error("Fuzzer apply with empty target section should fail, got:", val);
  process.exit(1);
}
NODE

apply_global="$(ucode -L "$TACHYON_LIB" -- "$FUZZER" apply desync "preset=auto" "global" 2>/dev/null || true)"
JSON_VALUE="$apply_global" node <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
if (val.success !== false) {
  console.error("Fuzzer apply with 'global' target section should fail, got:", val);
  process.exit(1);
}
NODE

# 11. Built-in presets include UDP-capable adaptive/discord strategies
JSON_VALUE="$strategies_json" node <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
const list = (val.desync || []).filter(
  (s) => /discord|adaptive|auto|udp/i.test((s.id || '') + ' ' + (s.name || '')),
);
if (list.length === 0) {
  console.error('No Discord/UDP-capable desync strategy found to verify');
  process.exit(1);
}
console.log(`Verified ${list.length} Discord/UDP-capable desync strategies.`);
NODE

# 12. Multi-URL custom targets resolution and validation (Issue #195)
ucode -L "$TACHYON_LIB" -e '
let binaries = require("diagnostics.fuzzer.binaries");
let runner = require("diagnostics.fuzzer_runner");

// A. Test newline-separated and comma-separated custom URLs list resolution
let multi_nl = "https://youtube.com\nhttps://instagram.com\nhttps://rutracker.org";
let list_nl = binaries.resolve_target_urls_list("custom", multi_nl);
if (length(list_nl) != 3) {
    warn(sprintf("Failed: expected 3 resolved URLs, got %d\n", length(list_nl)));
    exit(1);
}
if (list_nl[0].url != "https://youtube.com" || list_nl[1].url != "https://instagram.com" || list_nl[2].url != "https://rutracker.org") {
    warn("Failed: resolved URLs mismatch for newline-delimited input\n");
    exit(1);
}

let multi_comma = "https://youtube.com, https://instagram.com,https://rutracker.org";
let list_comma = binaries.resolve_target_urls_list("custom", multi_comma);
if (length(list_comma) != 3) {
    warn(sprintf("Failed: expected 3 resolved comma URLs, got %d\n", length(list_comma)));
    exit(1);
}

// B. Test resolve_target_url returns first URL
let primary = binaries.resolve_target_url("custom", multi_nl);
if (primary != "https://youtube.com") {
    warn(sprintf("Failed: resolve_target_url should return first URL, got %s\n", primary));
    exit(1);
}

// C. Test each URL in multi-URL string is valid
let urls = split(multi_nl, /[,\n]+/);
for (let u in urls) {
    let t = trim(u);
    if (t != "" && !runner.is_valid_url(t)) {
        warn(sprintf("Failed: valid URL %s was rejected\n", t));
        exit(1);
    }
}

// D. Test malformed URL in multi-URL string is caught
let multi_bad = "https://youtube.com\nhttps://evil.com;rm -rf /\nhttps://rutracker.org";
let bad_caught = false;
for (let u in split(multi_bad, /[,\n]+/)) {
    let t = trim(u);
    if (t != "" && !runner.is_valid_url(t)) {
        bad_caught = true;
        break;
    }
}
if (!bad_caught) {
    warn("Failed: malformed URL in multi-URL list was not detected\n");
    exit(1);
}

print("Multi-URL custom targets resolution and validation checks passed.\n");

// E. Verify Desync strategy parsing preserves multi_disorder, compound fooling, and symbolic/array split_pos
let ds_md = runner.parse_desync_outbound("mode=multi_disorder split_pos=sni fake_ttl=5 fake_sni=rutube.ru repeats=6", "desync-out");
if (!ds_md || ds_md.mode != "multi_disorder" || ds_md.split_pos != "sni" || ds_md.fake_ttl != 5) {
    warn(sprintf("Failed: multi_disorder strategy was misparsed: %J\n", ds_md));
    exit(1);
}
let ds_adv = runner.parse_desync_outbound("mode=multi_split split_pos=1,sni,midsld-2 fooling=md5_badack seqovl=8", "desync-out");
if (!ds_adv || ds_adv.mode != "multi_split" || ds_adv.fooling != "md5_badack" || type(ds_adv.split_pos) != "array" || length(ds_adv.split_pos) != 3) {
    warn(sprintf("Failed: advanced desync strategy was misparsed: %J\n", ds_adv));
    exit(1);
}
'

printf 'PASS: fuzzer_strategy_cli\n'

