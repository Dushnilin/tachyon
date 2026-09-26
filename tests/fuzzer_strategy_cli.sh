#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
FUZZER="$ROOT_DIR/tachyon/files/usr/lib/diagnostics/fuzzer.uc"
BYEDPI_VALIDATOR="$ROOT_DIR/tachyon/files/usr/lib/providers/byedpi/validator.uc"
ZAPRET_VALIDATOR="$ROOT_DIR/tachyon/files/usr/lib/providers/zapret/validator.uc"
ZAPRET2_VALIDATOR="$ROOT_DIR/tachyon/files/usr/lib/providers/zapret2/validator.uc"
TACHYON_BIN="$ROOT_DIR/tachyon/files/usr/bin/tachyon"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# 1. Check strategies JSON output
strategies_json="$(ucode -L "$TACHYON_LIB" -- "$FUZZER" strategies)"
[ -n "$strategies_json" ] || fail "fuzzer strategies returned empty output"

# Validate JSON structure using node
JSON_VALUE="$strategies_json" node <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
if (typeof val.available_engines !== 'object') {
  console.error("Missing available_engines");
  process.exit(1);
}
if (!Array.isArray(val.zapret2) || val.zapret2.length === 0) {
  console.error("Missing zapret2 strategies");
  process.exit(1);
}
if (!Array.isArray(val.zapret) || val.zapret.length === 0) {
  console.error("Missing zapret strategies");
  process.exit(1);
}
if (!Array.isArray(val.byedpi) || val.byedpi.length === 0) {
  console.error("Missing byedpi strategies");
  process.exit(1);
}
NODE

# 2. Check each strategy passes its respective engine validator
byedpi_args="$(JSON_VALUE="$strategies_json" node - <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
for (const s of val.byedpi) {
  console.log(s.args);
}
NODE
)"

while IFS= read -r args; do
  [ -n "$args" ] || continue
  check="$(ucode -L "$TACHYON_LIB" -- "$BYEDPI_VALIDATOR" validate-json "$args")"
  JSON_VALUE="$check" node - <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
if (!val.valid) {
  console.error("ByeDPI strategy invalid:", val);
  process.exit(1);
}
NODE
done <<< "$byedpi_args"

zapret_args="$(JSON_VALUE="$strategies_json" node - <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
for (const s of val.zapret) {
  console.log(s.args);
}
NODE
)"

while IFS= read -r args; do
  [ -n "$args" ] || continue
  check="$(ucode -L "$TACHYON_LIB" -- "$ZAPRET_VALIDATOR" validate-json nfqws "$args")"
  JSON_VALUE="$check" node - <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
if (!val.valid) {
  console.error("Zapret strategy invalid:", val);
  process.exit(1);
}
NODE
done <<< "$zapret_args"

zapret2_args="$(JSON_VALUE="$strategies_json" node - <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
for (const s of val.zapret2) {
  console.log(s.args);
}
NODE
)"

while IFS= read -r args; do
  [ -n "$args" ] || continue
  check="$(ucode -L "$TACHYON_LIB" -- "$ZAPRET2_VALIDATOR" validate-json nfqws2 "$args")"
  JSON_VALUE="$check" node - <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
if (!val.valid) {
  console.error("Zapret2 strategy invalid:", val);
  process.exit(1);
}
NODE
done <<< "$zapret2_args"

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
if (!Array.isArray(val.zapret2) || val.zapret2.length < 30) {
  console.error("Combinatorial zapret2 should have >= 30 strategies, got:", val.zapret2 ? val.zapret2.length : 0);
  process.exit(1);
}
if (!Array.isArray(val.zapret) || val.zapret.length < 20) {
  console.error("Combinatorial zapret should have >= 20 strategies, got:", val.zapret ? val.zapret.length : 0);
  process.exit(1);
}
if (!Array.isArray(val.byedpi) || val.byedpi.length < 20) {
  console.error("Combinatorial byedpi should have >= 20 strategies, got:", val.byedpi ? val.byedpi.length : 0);
  process.exit(1);
}
console.log("Generated matrix: Zapret2=" + val.zapret2.length + ", Zapret=" + val.zapret.length + ", ByeDPI=" + val.byedpi.length);
NODE

# 6. Check zapret2 Lua library resolution from LIB_DIR
lua_res="$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" -e '
let fs = require("fs");
let LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
let candidate_dirs = [
    getenv("ZAPRET2_PROVIDER_LUA_DIR"),
    LIB_DIR + "/providers/zapret2/lua",
    "/usr/lib/tachyon/providers/zapret2/lua"
];
let lua_scripts = [ "zapret-lib.lua", "zapret-antidpi.lua", "zapret-auto.lua" ];
let flags = "";
for (let script in lua_scripts) {
    let found = null;
    for (let d in candidate_dirs) {
        if (!d || fs.stat(d) == null) continue;
        let p = d + "/" + script;
        if (fs.stat(p) != null) { found = p; break; }
        if (fs.stat(p + ".gz") != null) { found = p + ".gz"; break; }
    }
    if (found != null) flags += sprintf("--lua-init=@%s ", found);
}
print(flags);
')"
echo "$lua_res" | grep -q 'zapret-lib.lua' || fail "missing zapret-lib.lua in resolved lua flags"
echo "$lua_res" | grep -q 'zapret-antidpi.lua' || fail "missing zapret-antidpi.lua in resolved lua flags"
echo "$lua_res" | grep -q 'zapret-auto.lua' || fail "missing zapret-auto.lua in resolved lua flags"

# 7. Check hardened runner, fail-closed validation, and absence of global killall curl
grep -q 'killall -9 curl' "$FUZZER" && fail "killall -9 curl must not be present in fuzzer.uc" || true

ucode -L "$TACHYON_LIB" -e '
let r = require("diagnostics.fuzzer_runner");

// 1. Fail-closed: unknown engine rejected
if (r.validate_strategy_args("unknown_engine", "--split-pos=1") !== false) {
    warn("Failed: unknown engine was not rejected\n");
    exit(1);
}

// 2. Fail-closed: shell metacharacters rejected
if (r.validate_strategy_args("zapret2", "--split-pos=1; rm -rf /") !== false) {
    warn("Failed: semicolon command injection was not rejected\n");
    exit(1);
}
if (r.validate_strategy_args("byedpi", "-s1 | reboot") !== false) {
    warn("Failed: pipe command injection was not rejected\n");
    exit(1);
}
if (r.validate_strategy_args("zapret", "--dpi-desync=split2 `reboot`") !== false) {
    warn("Failed: backtick command injection was not rejected\n");
    exit(1);
}
if (r.validate_strategy_args("zapret2", "--dpi-desync-split-pos=$(cat /etc/passwd)") !== false) {
    warn("Failed: command substitution was not rejected\n");
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
if (!Array.isArray(val.zapret2) || val.zapret2.length < 5) {
  console.error("Adaptive zapret2 should have >= 5 strategies, got:", val.zapret2 ? val.zapret2.length : 0);
  process.exit(1);
}
if (!Array.isArray(val.zapret) || val.zapret.length < 5) {
  console.error("Adaptive zapret should have >= 5 strategies, got:", val.zapret ? val.zapret.length : 0);
  process.exit(1);
}
if (!Array.isArray(val.byedpi) || val.byedpi.length < 5) {
  console.error("Adaptive byedpi should have >= 5 strategies, got:", val.byedpi ? val.byedpi.length : 0);
  process.exit(1);
}
console.log("Adaptive strategies generated: Zapret2=" + val.zapret2.length + ", Zapret=" + val.zapret.length + ", ByeDPI=" + val.byedpi.length);
NODE

# 10. Check that apply rejects global provider and requires valid target section
apply_empty="$(ucode -L "$TACHYON_LIB" -- "$FUZZER" apply zapret2 "--lua-desync=fake" "" 2>/dev/null || true)"
JSON_VALUE="$apply_empty" node <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
if (val.success !== false) {
  console.error("Fuzzer apply with empty target section should fail, got:", val);
  process.exit(1);
}
NODE

apply_global="$(ucode -L "$TACHYON_LIB" -- "$FUZZER" apply zapret2 "--lua-desync=fake" "global" 2>/dev/null || true)"
JSON_VALUE="$apply_global" node <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
if (val.success !== false) {
  console.error("Fuzzer apply with 'global' target section should fail, got:", val);
  process.exit(1);
}
NODE

printf 'PASS: fuzzer_strategy_cli\n'
