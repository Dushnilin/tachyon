#!/usr/bin/env bash
# Verifies sing-box pre-flight check resilience when connection sections have
# subscriptions but no local cache exists yet (e.g. fresh installation after
# firmware flash with restored UCI backup).
#
# 1. generator_outbounds auto-defers connection sections with no usable outbounds
#    during pre-flight candidate generation (SB_PREFLIGHT_BINARY).
# 2. verifier captures generator stderr on candidate config generation failure
#    and accurately distinguishes generator failures from binary rejection.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -z "$TACHYON_LIB" ]; then
  if [ -d "$ROOT_DIR/tachyon/files/usr/lib/components" ]; then
    TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
  else
    TACHYON_LIB="/usr/lib/tachyon"
  fi
fi

ucode() { command ucode -L "$TACHYON_LIB" "$@"; }

VERIFIER="$TACHYON_LIB/components/verifier.uc"
OUTBOUNDS="$TACHYON_LIB/singbox/generator_outbounds.uc"
ROUTES="$TACHYON_LIB/singbox/generator_routes.uc"
[ -f "$VERIFIER" ] || fail "missing $VERIFIER"
[ -f "$OUTBOUNDS" ] || fail "missing $OUTBOUNDS"
[ -f "$ROUTES" ] || fail "missing $ROUTES"

pass_count=0
ok() { pass_count=$((pass_count + 1)); }

# Check 1: generator_outbounds contains pre-flight auto-defer logic
if ! grep -q 'getenv("SB_PREFLIGHT_BINARY")' "$OUTBOUNDS"; then
  fail "generator_outbounds must check SB_PREFLIGHT_BINARY when connection section has no usable outbounds"
fi
ok

# Check 2: verifier captures candidate generation errors into err_file
verifier_body="$(sed -n '/^function check_sing_box_config_with_binary/,/^}/p' "$VERIFIER")"
[ -n "$verifier_body" ] || fail "check_sing_box_config_with_binary not found in $VERIFIER"

if ! grep -q 'common.shell_quote(err_file)' <<<"$verifier_body"; then
  fail "verifier candidate generation must redirect output to err_file, not /dev/null"
fi
ok

# Check 3: verifier distinguishes candidate generation failure from binary rejection
if ! grep -q 'is_gen_failure' <<<"$verifier_body"; then
  fail "verifier must distinguish candidate generation failure from binary rejection"
fi
ok

if ! grep -q 'unable to generate configuration' <<<"$verifier_body"; then
  fail "verifier must log generation failure message when generator fails"
fi
ok

# Check 4: generator_routes guards dns_detour_section when deferred
if ! grep -q 'ctx.deferred_sections\[detour_section\]' "$ROUTES"; then
  fail "generator_routes must check if dns_detour_section is deferred before adding detour route rules"
fi
ok

printf 'sing-box preflight uncached subscriptions: %d checks passed\n' "$pass_count"
printf 'PASS: sing_box_preflight_uncached_subscriptions\n'
