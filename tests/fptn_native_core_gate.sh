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
RUNTIME_UC="$TACHYON_LIB/providers/fptn/runtime.uc"
for f in "$VALIDATOR_UC" "$CONNECTIONS_UC" "$GENERATOR_UC" "$RUNTIME_UC"; do
  [ -f "$f" ] || fail "$(basename "$f") not found"
done

# The resolver is the single source of truth for the transport, and it exists.
grep -Fq 'function fptn_transport_mode' "$CONNECTIONS_UC" ||
  fail "config.connections must own the FPTN transport decision"
grep -Fq '"native"' "$CONNECTIONS_UC" ||
  fail "fptn_transport_mode must be able to resolve to native"

# Native really is a core-side outbound with no process behind it - otherwise
# "skip the binary check in native mode" would be a way to lose FPTN entirely.
grep -Fq 'type: "fptn"' "$GENERATOR_UC" ||
  fail "the generator must emit a native fptn outbound; without it native mode would be a lie"
grep -Fq 'fptn_transport_mode() == "native"' "$RUNTIME_UC" ||
  fail "the fptn provider runtime must stand down in native mode"

# The check under test.
body=$(awk '/^function check_provider_requirements\(/,/^}/' "$VALIDATOR_UC")
[ -n "$body" ] || fail "check_provider_requirements not found in config/validator.uc"

printf '%s' "$body" | grep -Fq 'fptn_transport_mode()' ||
  fail "the fptn provider check must consult fptn_transport_mode(); a bare binary probe is wrong on a native core"

# ...and it must be a gate on the check, not a log line next to it.
printf '%s' "$body" | grep -Eq 'if *\(.*fptn_transport_mode\(\) *== *"component"\)' ||
  fail "the fptn component-binary requirement must be gated on transport mode == component"

# The native branch must not demand the binary anywhere else either.
if printf '%s' "$body" | grep -A 6 'fptn_transport_mode()' | grep -q 'fptn-client'; then
  fail "the native branch still references the fptn-client binary"
fi

printf 'FPTN native transport checks passed\n'