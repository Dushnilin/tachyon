#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

DOCTOR="$TACHYON_LIB/diagnostics/doctor.uc"
SETTINGS="$ROOT_DIR/luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/settings.js"

[ -f "$DOCTOR" ] || fail "doctor.uc not found at $DOCTOR"
[ -f "$SETTINGS" ] || fail "settings.js not found at $SETTINGS"

# 1. Resolv.conf validation helper and checks
grep -Fq 'function is_valid_resolv_conf(' "$DOCTOR" ||
  fail "doctor.uc must define is_valid_resolv_conf() helper"

grep -Fq '"/tmp/resolv.conf.d/resolv.conf.auto"' "$DOCTOR" ||
  fail "is_valid_resolv_conf must recognize /tmp/resolv.conf.d/resolv.conf.auto symlink target"

grep -Fq 'has_nameserver' "$DOCTOR" ||
  fail "is_valid_resolv_conf must validate regular files containing nameserver directives"

grep -Fq 'let resolv_info = is_valid_resolv_conf();' "$DOCTOR" ||
  fail "check_dns and quick_fix_network must use is_valid_resolv_conf()"

# 2. History debouncing and incident clustering
grep -Fq 'now - int(last.ts || 0) < 300' "$DOCTOR" ||
  fail "doctor_history_record must debounce rapid consecutive entries within 300s"

grep -Fq '(ts - last_ts) >= 600' "$DOCTOR" ||
  fail "doctor_history_trend must cluster failure runs within 600s interval"

# 3. Quick-fix extraction: preserve underscore and validate against allowlist
grep -Fq 'DOCTOR_FIX_PRIORITIES[first_token] != null' "$DOCTOR" ||
  fail "ai_doctor must validate extracted quick fixes against DOCTOR_FIX_PRIORITIES allowlist"

# Check that the regex does NOT strip underscores: /[._`*]/g was the bug
if grep -Fq 'replace(code, /[._`*]/g, "")' "$DOCTOR"; then
  fail "doctor.uc still strips underscores from quick-fix codes using /[._\`*]/g"
fi

# 4. Gemini provider support
grep -Fq 'provider == "gemini"' "$DOCTOR" ||
  fail "query_llm in doctor.uc must natively handle gemini provider"

grep -Fq 'generativelanguage.googleapis.com' "$DOCTOR" ||
  fail "query_llm must support Google Gemini API endpoint"

grep -Fq 'o.value("gemini"' "$SETTINGS" ||
  fail "settings.js must offer Google Gemini provider option"

# 5. Diagnostic evidence citation instructions in prompt
grep -Fq 'cite concrete evidence' "$DOCTOR" ||
  fail "English prompt must instruct LLM to cite concrete diagnostic evidence"

grep -Fq 'конкретные подтверждения и симптомы' "$DOCTOR" ||
  fail "Russian prompt must instruct LLM to cite concrete diagnostic evidence"

# 6. Dynamic ucode test if ucode is available in environment
if command -v ucode >/dev/null 2>&1; then
  # Test quick-fix token parsing logic in ucode
  ucode_test='
  const DOCTOR_FIX_PRIORITIES = {
      "fix_system_time": 5,
      "fix_uci_config": 8,
      "fix_wan_interface": 10,
      "fix_resolv_symlink": 30,
      "start_singbox": 50
  };

  let test_ai_res = "Some diagnosis text\nFIX: `fix_resolv_symlink`., invalid_code_123,  start_singbox \n";
  let quick_fixes = [];
  let fix_idx = index(test_ai_res, "FIX:");
  if (fix_idx >= 0) {
      let fix_part = trim(substr(test_ai_res, fix_idx + 4));
      let raw_codes = split(fix_part, /[,\r\n]+/);
      let seen = {};
      for (let code in raw_codes) {
          let clean_code = trim(replace(code, /[`*#]/g, ""));
          clean_code = replace(clean_code, /^[ \t\-_.:]+|[ \t\-_.:]+$/g, "");
          let first_token = lc(trim(split(clean_code, /[ \t,;:]+/)[0]));
          if (first_token != "" && DOCTOR_FIX_PRIORITIES[first_token] != null) {
              if (!seen[first_token]) {
                  seen[first_token] = true;
                  push(quick_fixes, first_token);
              }
          }
      }
  }

  if (length(quick_fixes) != 2 || quick_fixes[0] != "fix_resolv_symlink" || quick_fixes[1] != "start_singbox") {
      warn("Quick fix parsing failed: " + sprintf("%J\n", quick_fixes));
      exit(1);
  }
  exit(0);
  '
  ucode -e "$ucode_test" || fail "dynamic ucode quick-fix parsing test failed"
fi

printf 'ai_doctor resolv.conf, quick-fix and gemini checks passed\n'
