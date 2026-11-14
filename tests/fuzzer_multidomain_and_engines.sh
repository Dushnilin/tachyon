#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

FUZZER="$ROOT_DIR/tachyon/files/usr/lib/diagnostics/fuzzer.uc"

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/state"

export TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state"
export TACHYON_FUZZER_STATE_DIR="$WORK_DIR/state"
export TACHYON_LIB

cat >"$WORK_DIR/bin/nslookup" <<'SH'
#!/usr/bin/env bash
printf 'Server:    1.1.1.1\nAddress:   1.1.1.1#53\n\nName:      %s\nAddress: 93.184.216.34\n' "${1:-example.com}"
SH
chmod +x "$WORK_DIR/bin/nslookup"

cat >"$WORK_DIR/bin/tachyon" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$WORK_DIR/bin/tachyon"

export PATH="$WORK_DIR/bin:$PATH"

# 1. binaries.get_desync_bin() must NOT fall back to /usr/bin/sing-box
env -u TACHYON_CORE_BIN ucode -L "$TACHYON_LIB" - <<'UCODE'
let fs_mod = require("fs");
let orig_stat = fs_mod.stat;
let orig_access = fs_mod.access;
fs_mod.stat = function(p) {
    if (p == "/usr/bin/sing-box") return { type: "file", size: 1024 };
    if (p == "/usr/bin/tachyon-core") return null;
    return orig_stat(p);
};
fs_mod.access = function(p, m) {
    if (p == "/usr/bin/sing-box") return true;
    if (p == "/usr/bin/tachyon-core") return false;
    return orig_access(p, m);
};
let binaries = require("diagnostics.fuzzer.binaries");
let bin = binaries.get_desync_bin();
if (bin != null) {
    warn(sprintf("FAIL: get_desync_bin() fell back to %J when only sing-box existed\n", bin));
    exit(1);
}
print("OK: get_desync_bin rejects sing-box fallback\n");
UCODE

printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/tachyon-core"
chmod +x "$WORK_DIR/tachyon-core"
export WORK_TACHYON_CORE="$WORK_DIR/tachyon-core"
TACHYON_CORE_BIN="$WORK_TACHYON_CORE" ucode -L "$TACHYON_LIB" - <<'UCODE'
let binaries = require("diagnostics.fuzzer.binaries");
let expected = getenv("WORK_TACHYON_CORE");
let bin = binaries.get_desync_bin();
if (bin != expected) {
    warn(sprintf("FAIL: expected %s, got %J\n", expected, bin));
    exit(1);
}
print("OK: get_desync_bin resolves tachyon-core binary\n");
UCODE

# 2. Normalization and validation of multi-domain / bare domain input
ucode -L "$TACHYON_LIB" - <<'UCODE'
let runner = require("diagnostics.fuzzer_runner");
let binaries = require("diagnostics.fuzzer.binaries");

if (type(runner.normalize_target_url) != "function") {
    warn("FAIL: fuzzer_runner.normalize_target_url is missing\n");
    exit(1);
}
if (type(runner.validate_custom_targets_input) != "function") {
    warn("FAIL: fuzzer_runner.validate_custom_targets_input is missing\n");
    exit(1);
}

if (runner.normalize_target_url("youtube.com") != "https://youtube.com") {
    warn(sprintf("FAIL: normalize bare domain -> %J\n", runner.normalize_target_url("youtube.com")));
    exit(1);
}
if (runner.normalize_target_url("example.org:8443/path") != "https://example.org:8443/path") {
    warn(sprintf("FAIL: normalize host:port/path -> %J\n", runner.normalize_target_url("example.org:8443/path")));
    exit(1);
}
if (runner.normalize_target_url("udp://stun.l.google.com:19302") != "udp://stun.l.google.com:19302") {
    warn(sprintf("FAIL: normalize udp:// -> %J\n", runner.normalize_target_url("udp://stun.l.google.com:19302")));
    exit(1);
}

let val_ok = runner.validate_custom_targets_input("youtube.com\ndiscord.com, example.org:8443/path; youtube.com  https://twitch.tv");
if (!val_ok || !val_ok.valid || type(val_ok.urls) != "array" || length(val_ok.urls) != 4 ||
    val_ok.urls[0] != "https://youtube.com" ||
    val_ok.urls[1] != "https://discord.com" ||
    val_ok.urls[2] != "https://example.org:8443/path" ||
    val_ok.urls[3] != "https://twitch.tv") {
    warn(sprintf("FAIL: validate_custom_targets_input mismatch: %J\n", val_ok));
    exit(1);
}

let val_bad = runner.validate_custom_targets_input("youtube.com\nevil.com;id");
if (!val_bad || val_bad.valid) {
    warn(sprintf("FAIL: injection input was accepted: %J\n", val_bad));
    exit(1);
}

let resolved = binaries.resolve_target_urls_list("custom", "youtube.com\ndiscord.com, example.org:8443/path");
if (type(resolved) != "array" || length(resolved) != 3) {
    warn(sprintf("FAIL: expected 3 resolved URLs, got %J\n", resolved));
    exit(1);
}
if (resolved[0].url != "https://youtube.com" || resolved[0].name != "youtube.com" ||
    resolved[1].url != "https://discord.com" || resolved[1].name != "discord.com" ||
    resolved[2].url != "https://example.org:8443/path" || resolved[2].name != "example.org:8443") {
    warn(sprintf("FAIL: unexpected resolved targets: %J\n", resolved));
    exit(1);
}
print("OK: multi-domain normalization and target naming\n");
UCODE

# 3. Port pinning in binaries.get_resolved_host_flags
ucode -L "$TACHYON_LIB" - <<'UCODE'
let binaries = require("diagnostics.fuzzer.binaries");
let flags = binaries.get_resolved_host_flags("https://cdn.example.com:8443/probe");
if (index(flags, "--resolve cdn.example.com:8443:93.184.216.34") < 0) {
    warn(sprintf("FAIL: explicit port 8443 missing from --resolve flags: %J\n", flags));
    exit(1);
}
if (index(flags, "--resolve cdn.example.com:443:93.184.216.34") < 0) {
    warn(sprintf("FAIL: port 443 missing from --resolve flags: %J\n", flags));
    exit(1);
}
print("OK: explicit port pinned in --resolve flags\n");
UCODE

# 4. Reject 'all', global sections, and non-DPI proxy connection sections
cat >"$TACHYON_UCI_STATE_FILE" <<'STATE'
tachyon.global_sec=section
tachyon.global_sec.name=Global Rule
tachyon.global_sec.action=zapret2
tachyon.global_sec.match_all=1
tachyon.proxy_sec=section
tachyon.proxy_sec.name=Proxy Rule
tachyon.proxy_sec.action=connection
tachyon.proxy_sec.outbound_source_refs=sub_main
tachyon.sub_main=outbound_source
tachyon.sub_main.source_type=subscription
tachyon.dpi_src=outbound_source
tachyon.dpi_src.source_type=zapret2
tachyon.mod_dpi_sec=section
tachyon.mod_dpi_sec.action=connection
tachyon.mod_dpi_sec.outbound_source_refs=dpi_src
tachyon.direct_z2_sec=section
tachyon.direct_z2_sec.action=zapret2
STATE

start_all="$(ucode -L "$TACHYON_LIB" -- "$FUZZER" start all youtube_suite 2>/dev/null || true)"
JSON_VALUE="$start_all" node - <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
if (val.success !== false) {
  console.error("FAIL: start with 'all' engine must fail, got:", val);
  process.exit(1);
}
NODE

apply_global_sec="$(ucode -L "$TACHYON_LIB" -- "$FUZZER" apply zapret2 "--lua-desync=fake:blob=fake_default_tls:tcp_md5" global_sec 2>/dev/null || true)"
JSON_VALUE="$apply_global_sec" node - <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
if (val.success !== false) {
  console.error("FAIL: apply to match_all=1 global section must fail, got:", val);
  process.exit(1);
}
NODE

apply_proxy_sec="$(ucode -L "$TACHYON_LIB" -- "$FUZZER" apply zapret2 "--lua-desync=fake:blob=fake_default_tls:tcp_md5" proxy_sec 2>/dev/null || true)"
JSON_VALUE="$apply_proxy_sec" node - <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
if (val.success !== false) {
  console.error("FAIL: apply to proxy connection section must fail, got:", val);
  process.exit(1);
}
NODE

if grep -q 'src_zapret2_proxy_sec' "$TACHYON_UCI_STATE_FILE"; then
  fail "apply created unexpected src_zapret2_proxy_sec on proxy connection section"
fi

apply_mod_dpi="$(ucode -L "$TACHYON_LIB" -- "$FUZZER" apply zapret2 "--lua-desync=fake:blob=fake_default_tls:tcp_md5" mod_dpi_sec 2>/dev/null)"
JSON_VALUE="$apply_mod_dpi" node - <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
if (val.success !== true) {
  console.error("FAIL: apply to modular DPI connection section should succeed, got:", val);
  process.exit(1);
}
NODE

if ! grep -q '^tachyon\.dpi_src\.nfqws2_opt=' "$TACHYON_UCI_STATE_FILE" || ! grep -q '^tachyon\.mod_dpi_sec\.nfqws2_opt=' "$TACHYON_UCI_STATE_FILE"; then
  fail "apply to modular DPI connection section did not persist nfqws2_opt to both source and section"
fi

apply_direct_z2="$(ucode -L "$TACHYON_LIB" -- "$FUZZER" apply zapret2 "--lua-desync=fake:blob=fake_default_tls:tcp_md5" direct_z2_sec 2>/dev/null)"
JSON_VALUE="$apply_direct_z2" node - <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
if (val.success !== true) {
  console.error("FAIL: apply to direct zapret2 section should succeed, got:", val);
  process.exit(1);
}
NODE

if ! grep -q '^tachyon\.direct_z2_sec\.nfqws2_opt=' "$TACHYON_UCI_STATE_FILE"; then
  fail "apply to direct zapret2 section did not persist nfqws2_opt"
fi

# 5. Preserve compact per-domain sub_probes and endpoint counts in status output
cat >"$TACHYON_FUZZER_STATE_DIR/fuzzer-state.json" <<'JSON'
{
  "running": false,
  "job_id": "job_test_multi",
  "engine": "zapret2",
  "target": "custom",
  "mode": "presets",
  "progress_pct": 100,
  "current_index": 1,
  "total_strategies": 1,
  "results": [
    {
      "id": "z2_test",
      "name": "TLS Fake + Split",
      "engine": "zapret2",
      "args": "--lua-desync=fake:blob=fake_default_tls:tcp_md5",
      "success": false,
      "http_code": 200,
      "handshake_ms": 40,
      "ttfb_ms": 85,
      "speed_kbps": 512,
      "score": 0,
      "passed_endpoints": 1,
      "total_endpoints": 2,
      "badge": "Best Match",
      "sub_probes": [
        {
          "target_name": "youtube.com",
          "url": "https://youtube.com",
          "http_code": 200,
          "handshake_ms": 40,
          "ttfb_ms": 85,
          "speed_kbps": 512,
          "success": true
        },
        {
          "target_name": "discord.com",
          "url": "https://discord.com",
          "http_code": 0,
          "handshake_ms": 0,
          "ttfb_ms": 0,
          "speed_kbps": 0,
          "success": false,
          "error": "TLS timeout"
        }
      ]
    }
  ],
  "best_strategy": null,
  "error": null,
  "aborted": false,
  "started_at": 1000,
  "finished_at": 1005
}
JSON

status_out="$(ucode -L "$TACHYON_LIB" -- "$FUZZER" status)"
JSON_VALUE="$status_out" node - <<'NODE'
const st = JSON.parse(process.env.JSON_VALUE);
const r = st.results && st.results[0];
if (!r) {
  console.error("FAIL: missing result in status output:", st);
  process.exit(1);
}
if (r.passed_endpoints !== 1 || r.total_endpoints !== 2) {
  console.error("FAIL: passed_endpoints/total_endpoints lost in status:", r);
  process.exit(1);
}
if (!Array.isArray(r.sub_probes) || r.sub_probes.length !== 2) {
  console.error("FAIL: sub_probes missing in status:", r);
  process.exit(1);
}
if (r.sub_probes[0].target_name !== "youtube.com" || r.sub_probes[0].http_code !== 200 || r.sub_probes[0].ttfb_ms !== 85) {
  console.error("FAIL: sub_probes fields stripped in slim_fuzzer_item:", r.sub_probes);
  process.exit(1);
}
if (r.sub_probes[1].target_name !== "discord.com" || r.sub_probes[1].success !== false) {
  console.error("FAIL: second sub_probe fields incorrect:", r.sub_probes);
  process.exit(1);
}
NODE

printf 'PASS: fuzzer_multidomain_and_engines\n'
