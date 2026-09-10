#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
LEAK_CHECK="$TACHYON_LIB/diagnostics/leak_check.uc"
BIN="$ROOT_DIR/tachyon/files/usr/bin/tachyon"
API_UC="$TACHYON_LIB/service/api.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# ─── 1. Syntax check & module load ──────────────────────────────────────────
ucode -L "$TACHYON_LIB" -c "$LEAK_CHECK" || fail "leak_check.uc must pass ucode syntax check"
ucode -S -L "$TACHYON_LIB" -c "$LEAK_CHECK" || fail "leak_check.uc must pass strict ucode syntax check"

# ─── 2. Test logic with synthetic inputs ────────────────────────────────────
cat >"$WORK_DIR/test_leak_logic.uc" <<'UCODE'
let leak_mod = require("diagnostics.leak_check");

if (type(leak_mod) != "object") {
    print("ERR: leak_check module must export object\n");
    exit(1);
}

// Test exports
if (type(leak_mod.check_ip_leak) != "function" ||
    type(leak_mod.check_dns_leak) != "function" ||
    type(leak_mod.run_leak_check) != "function" ||
    type(leak_mod.start_leak_check_async) != "function" ||
    type(leak_mod.get_leak_check_status) != "function") {
    print("ERR: leak_check module missing required functions\n");
    exit(2);
}

// Test direct curl flags generation
let flags = leak_mod.get_direct_curl_flags("eth0");
if (index(flags, "--interface 'eth0'") < 0 && index(flags, "--interface eth0") < 0) {
    print("ERR: direct curl flags must specify wan interface\n");
    exit(3);
}

print("OK\n");
exit(0);
UCODE

ucode -L "$TACHYON_LIB" "$WORK_DIR/test_leak_logic.uc" | grep -q "OK" ||
  fail "leak_check.uc unit logic validation failed"

# ─── 3. Test CLI registration in /usr/bin/tachyon ───────────────────────────
grep -Fq "leak_check" "$BIN" || fail "/usr/bin/tachyon must register leak_check"
grep -Fq "leak_check_async" "$BIN" || fail "/usr/bin/tachyon must register leak_check_async"
grep -Fq "leak_check_status" "$BIN" || fail "/usr/bin/tachyon must register leak_check_status"
grep -Fq "check_ip_leak" "$BIN" || fail "/usr/bin/tachyon must register check_ip_leak"
grep -Fq "check_dns_leak" "$BIN" || fail "/usr/bin/tachyon must register check_dns_leak"

# ─── 4. Test api.uc integration ─────────────────────────────────────────────
grep -Fq "run_leak_check" "$API_UC" || fail "api.uc must export run_leak_check"
grep -Fq "run_leak_check_async" "$API_UC" || fail "api.uc must export run_leak_check_async"
grep -Fq "run_leak_check_status" "$API_UC" || fail "api.uc must export run_leak_check_status"
grep -Fq "run_ip_leak_check" "$API_UC" || fail "api.uc must export run_ip_leak_check"
grep -Fq "run_dns_leak_check" "$API_UC" || fail "api.uc must export run_dns_leak_check"

printf 'PASS: leak_check\n'
