#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
export TACHYON_LIB="$TACHYON_LIB"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# 1. Verify runtime.uc owns local_rule_doctor
grep -Fq 'function local_rule_doctor()' "$TACHYON_LIB/diagnostics/runtime.uc" ||
  fail "runtime.uc must define local_rule_doctor heuristic engine"

# 2. Run ai-doctor without API key (local offline mode)
output="$(ucode -L "$TACHYON_LIB" "$TACHYON_LIB/diagnostics/runtime.uc" ai-doctor 2>/dev/null || true)"

echo "$output" | grep -Fq '"success": true' ||
  fail "ai-doctor in offline mode must return success: true"

echo "$output" | grep -Fq '"provider": "local_heuristic"' ||
  fail "ai-doctor in offline mode must report provider local_heuristic"

# 3. Test apply-quick-fix for new codes
fix_out="$(ucode -L "$TACHYON_LIB" "$TACHYON_LIB/diagnostics/runtime.uc" apply-quick-fix "restart_zapret,optimize_memory" 2>/dev/null || true)"

echo "$fix_out" | grep -Fq '"code": "restart_zapret"' ||
  fail "apply_quick_fix must handle restart_zapret"

echo "$fix_out" | grep -Fq '"code": "optimize_memory"' ||
  fail "apply_quick_fix must handle optimize_memory"

# 4. Doctor must work with the service stopped (recovery mode: restore stock
#    internet, never start Tachyon) and the AI Doctor must verify the system
#    end-to-end instead of trusting a point-in-time snapshot.
grep -Fq 'function tachyon_is_running()' "$TACHYON_LIB/diagnostics/runtime.uc" ||
  fail "runtime.uc must define tachyon_is_running()"
grep -Fq 'return run_recovery_checks();' "$TACHYON_LIB/diagnostics/runtime.uc" ||
  fail "doctor no longer dispatches to recovery mode when the service is stopped"
grep -Fq 'function run_recovery_checks()' "$TACHYON_LIB/diagnostics/runtime.uc" ||
  fail "runtime.uc must define run_recovery_checks()"
grep -Fq 'function verify_system()' "$TACHYON_LIB/diagnostics/runtime.uc" ||
  fail "runtime.uc must define verify_system()"
grep -Fq 'let verify = verify_system();' "$TACHYON_LIB/diagnostics/runtime.uc" ||
  fail "local_rule_doctor no longer feeds live verification into its analysis"
grep -Fq 'wan_fail_streak: int(st.wan_fail_streak || 0)' "$TACHYON_LIB/service/watchdog.uc" ||
  fail "watchdog status export no longer reports probe streaks to AI Doctor"

# 5. Fix usage tracker: applying the same fix must be recorded, and fixes
#    applied 3+ times within the hour must be withheld from recommendations
#    (issue #31: doctor proposing the same repairs forever).
rm -f /tmp/tachyon_doctor_fixes.json
for i in 1 2 3; do
  ucode -L "$TACHYON_LIB" "$TACHYON_LIB/diagnostics/runtime.uc" apply-quick-fix "clear_dns_cache" >/dev/null 2>&1 || true
done
grep -Fq '"clear_dns_cache"' /tmp/tachyon_doctor_fixes.json ||
  fail "apply_quick_fix must record applied fixes in the doctor usage tracker"
grep -Eq '"count": ?3' /tmp/tachyon_doctor_fixes.json ||
  fail "doctor usage tracker must count repeated applications"
grep -Fq 'function doctor_fix_overused(' "$TACHYON_LIB/diagnostics/runtime.uc" ||
  fail "runtime.uc must define doctor_fix_overused()"
grep -Fq 'if (doctor_fix_overused(code)) return;' "$TACHYON_LIB/diagnostics/runtime.uc" ||
  fail "add_fix must withhold overused fixes"

printf 'local AI Doctor checks passed\n'
