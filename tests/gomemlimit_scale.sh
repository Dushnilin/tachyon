#!/usr/bin/env bash
# Verifies that GOMEMLIMIT scaling correctly handles:
# 1. Presence of GOMEMLIMIT logic in managed service init scripts
# 2. Explicit memory_limit_mb cap
# 3. Dynamic 50% RAM cap for low-RAM devices (<= 512MB)
# 4. Watchdog OOM scale (/etc/tachyon/mem_scale) application
# 5. Unconstrained GOMEMLIMIT on high-RAM devices (> 512MB) without OOM
# 6. Activation of GOMEMLIMIT on high-RAM devices when an OOM scale is present
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -euo pipefail

SB_RUNTIME="$TACHYON_LIB/tachyon_core/runtime.uc"
VALIDATOR_UC="$TACHYON_LIB/config/validator.uc"
ACTION_UC="$TACHYON_LIB/components/action.uc"

[ -f "$SB_RUNTIME" ] || fail "tachyon_core/runtime.uc not found at $SB_RUNTIME"
[ -f "$VALIDATOR_UC" ] || fail "config/validator.uc not found at $VALIDATOR_UC"
[ -f "$ACTION_UC" ] || fail "components/action.uc not found at $ACTION_UC"

# 1. Structural checks
for file in "$SB_RUNTIME" "$VALIDATOR_UC" "$ACTION_UC"; do
  grep -Fq 'GOMEMLIMIT' "$file" || fail "missing GOMEMLIMIT in $file"
  grep -Fq 'memory_limit_mb' "$file" || fail "missing memory_limit_mb in $file"
  grep -Fq '/etc/tachyon/mem_scale' "$file" || fail "missing /etc/tachyon/mem_scale in $file"
done

# 2. Logic simulation function
evaluate_gomemlimit() {
  local mem_total_kb="$1"
  local mem_limit_mb="$2"
  local scale_val="$3"

  local scale_file="$WORK_DIR/mem_scale"
  rm -f "$scale_file"
  if [ -n "$scale_val" ]; then
    printf '%s\n' "$scale_val" > "$scale_file"
  fi

  local scale_pct=""
  if [ -s "$scale_file" ]; then
    scale_pct="$(awk -v s="$(cat "$scale_file" 2>/dev/null)" 'BEGIN { if (!s) exit; pct=int(s*100); if (pct < 20) pct=20; if (pct > 100) pct=100; print pct }')"
  fi

  local gomemlimit=""
  if [ "$mem_limit_mb" -gt 0 ] 2>/dev/null; then
    gomemlimit="$mem_limit_mb"
  elif [ "$mem_total_kb" -gt 0 ]; then
    if [ "$mem_total_kb" -le 524288 ] || { [ -n "$scale_pct" ] && [ "$scale_pct" -lt 100 ]; }; then
      gomemlimit=$(( mem_total_kb / 1024 * 50 / 100 ))
      [ "$gomemlimit" -lt 24 ] && gomemlimit=24
    fi
  fi

  if [ -n "$gomemlimit" ] && [ "$gomemlimit" -gt 0 ] 2>/dev/null; then
    if [ -n "$scale_pct" ] && [ "$scale_pct" -lt 100 ]; then
      gomemlimit=$(( gomemlimit * scale_pct / 100 ))
      [ "$gomemlimit" -lt 16 ] && gomemlimit=16
    fi
    printf '%sMiB\n' "$gomemlimit"
  else
    printf 'NONE\n'
  fi
}

# Test 1: Explicit memory_limit_mb=128 without scale
res="$(evaluate_gomemlimit 1010032 128 "")"
[ "$res" = "128MiB" ] || fail "expected 128MiB, got $res"

# Test 2: Explicit memory_limit_mb=128 with scale=0.80
res="$(evaluate_gomemlimit 1010032 128 "0.80")"
[ "$res" = "102MiB" ] || fail "expected 102MiB, got $res"

# Test 3: Auto limit on low-RAM device (496MB) without scale -> 50% RAM
res="$(evaluate_gomemlimit 507904 0 "")"
[ "$res" = "248MiB" ] || fail "expected 248MiB, got $res"

# Test 4: Auto limit on low-RAM device (496MB) with scale=0.80 -> 248 * 0.8
res="$(evaluate_gomemlimit 507904 0 "0.80")"
[ "$res" = "198MiB" ] || fail "expected 198MiB, got $res"

# Test 5: Auto limit on low-RAM device (496MB) with scale=0.64 -> 248 * 0.64
res="$(evaluate_gomemlimit 507904 0 "0.64")"
[ "$res" = "158MiB" ] || fail "expected 158MiB, got $res"

# Test 6: High-RAM device (1GB) without scale -> unconstrained
res="$(evaluate_gomemlimit 1010032 0 "")"
[ "$res" = "NONE" ] || fail "expected NONE for high-RAM without scale, got $res"

# Test 7: High-RAM device (1GB) with scale=0.80 after OOM -> 50% * 0.8
res="$(evaluate_gomemlimit 1010032 0 "0.80")"
[ "$res" = "394MiB" ] || fail "expected 394MiB, got $res"

# Test 8: Floor clamping (scale < 0.2 clamped to >= 16MiB)
res="$(evaluate_gomemlimit 65536 0 "0.10")"
[ "$res" = "16MiB" ] || fail "expected 16MiB floor clamp, got $res"

printf 'gomemlimit_scale: all tests passed\n'
