#!/usr/bin/env bash
# FAULT: with tachyon-core, FPTN is native - demanding the client binary is wrong.
#
# Found on a live router running tachyon-core 0.0.3. The admin had never
# installed the fptn package and never needed to: fptn_transport_mode() in
# config/connections.uc resolves to "native" whenever the core is tachyon-core,
# the generator emits an `fptn` outbound into config.json, and the core dials
# the tunnel itself - no external process, no shims, no state directory.
#
# check_provider_requirements() asked for /usr/bin/fptn-client anyway and logged
# "[error] FPTN provider is not available at /usr/bin/fptn-client. Rules with
# action 'fptn' will be skipped until the fptn package is installed." That is
# false twice over: the rules are not skipped, and the package is irrelevant.
# It also returned before preparing the state dir - the right behaviour for a
# component runtime, the wrong one to key off a binary instead of off the
# transport the core actually uses.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

VALIDATOR_UC="$TACHYON_LIB/config/validator.uc"
CONNECTIONS_UC="$TACHYON_LIB/config/connections.uc"
GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator_outbounds.uc"
for f in "$VALIDATOR_UC" "$CONNECTIONS_UC" "$GENERATOR_UC"; do
  [ -f "$f" ] || fail "$(basename "$f") not found"
done

# 1. fptn_transport_mode() resolves to "native" on tachyon-core and "" on sing-box.
printf 'tachyon-core\n' > "$WORK_DIR/variant-core"
MODE_CORE="$(SB_VARIANT_STATE_FILE="$WORK_DIR/variant-core" ucode -L "$TACHYON_LIB" -e '
let c = require("config.connections");
printf("%s", c.fptn_transport_mode());
')"
[ "$MODE_CORE" = "native" ] || fail "expected fptn_transport_mode() == 'native' on tachyon-core, got '$MODE_CORE'"

printf 'stable\n' > "$WORK_DIR/variant-sb"
MODE_SB="$(SB_VARIANT_STATE_FILE="$WORK_DIR/variant-sb" TACHYON_CORE_ENGINE="sing-box" ucode -L "$TACHYON_LIB" -e '
let c = require("config.connections");
printf("%s", c.fptn_transport_mode());
')"
[ "$MODE_SB" = "" ] || fail "expected fptn_transport_mode() == '' on sing-box, got '$MODE_SB'"

# 2. Native is a core-side outbound gated on core capability, with no external client binary or routing_mark fallback.
grep -Fq 'type: "fptn"' "$GENERATOR_UC" ||
  fail "the generator must emit a native fptn outbound"
grep -Fq 'ensure_fptn_outbound_supported()' "$GENERATOR_UC" ||
  fail "add_fptn_outbound must enforce ensure_fptn_outbound_supported()"
if grep -Fq '3145728' "$GENERATOR_UC"; then
  fail "generator_outbounds.uc must not contain legacy 3145728 component routing_mark fallback"
fi

# 3. validator.uc must never probe /usr/bin/fptn-client*.
if grep -Fq 'fptn-client' "$VALIDATOR_UC"; then
  fail "config/validator.uc still references external fptn-client binary"
fi

printf 'FPTN native transport checks passed\n'