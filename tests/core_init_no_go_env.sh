#!/usr/bin/env bash
# Verifies that managed tachyon-core init scripts and verifiers emit zero Go
# runtime variables (GOMEMLIMIT, GOGC, GODEBUG) and mark legacy 1.7.x scripts
# containing them as stale for regeneration.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

for f in \
  "$TACHYON_LIB/core/process.uc" \
  "$TACHYON_LIB/tachyon_core/runtime.uc" \
  "$TACHYON_LIB/components/action.uc" \
  "$TACHYON_LIB/components/verifier.uc"
do
  [ -f "$f" ] || fail "missing $f"
done

script_out="$(ucode -L "$TACHYON_LIB" -e '
let proc = require("core.process");
print(proc.managed_core_init_script("Tachyon managed tachyon-core service", true));
')"

for forbidden in GOMEMLIMIT GOGC GODEBUG mem_scale; do
  if printf '%s' "$script_out" | grep -Fq "$forbidden"; then
    fail "managed_core_init_script must not emit $forbidden"
  fi
done

printf '%s' "$script_out" | grep -Fq 'TACHYON_RULESET_SOFT_START="1"' ||
  fail "managed_core_init_script must still set TACHYON_RULESET_SOFT_START"

if grep -REq 'GOMEMLIMIT|GOGC|GODEBUG="madvdontneed=1"' \
  "$TACHYON_LIB/core/process.uc" \
  "$TACHYON_LIB/components/verifier.uc" \
  "$TACHYON_LIB/diagnostics/routing.uc" \
  "$TACHYON_LIB/tachyon_core/rulesets.uc"
then
  fail "found leftover Go runtime env setup in Rust-only runtime modules"
fi

if grep -qE 'madvdontneed|GOGC=|mem_scale' "$TACHYON_LIB/tachyon_core/runtime.uc" && \
   grep -vE 'index\((data|s), "(GOGC=|GODEBUG=|GOMEMLIMIT)"\)' "$TACHYON_LIB/tachyon_core/runtime.uc" | grep -qE 'GODEBUG=|GOGC=|mem_scale|GOMEMLIMIT'; then
  fail "found leftover Go runtime env setup in tachyon_core/runtime.uc"
fi

grep -Fq 'index(data, "GOMEMLIMIT") >= 0' "$TACHYON_LIB/tachyon_core/runtime.uc" ||
  fail "managed_service_script_stale must flag old scripts with GOMEMLIMIT for regeneration"

printf 'PASS: core_init_no_go_env\n'
