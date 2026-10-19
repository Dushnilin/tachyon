#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

APPLY_UC="$ROOT_DIR/tachyon/files/usr/lib/nft/apply.uc"
LIFECYCLE_UC="$ROOT_DIR/tachyon/files/usr/lib/service/lifecycle.uc"

# Invariant 1: nft_add_community_subnet_file_for_section must ensure priority sets exist
# when section_needs_priority_sets(section) is true, preventing nftables syntax/missing set errors.
if ! awk '/function nft_add_community_subnet_file_for_section/,/^}/' "$APPLY_UC" | grep -q 'nft_create_priority_sets(table, sets)'; then
  fail "nft_add_community_subnet_file_for_section must call nft_create_priority_sets(table, sets) when priority sets are needed"
fi

# Invariant 2: lifecycle.uc must not use obsolete 'pidof sing-box', but query tachyon-core-service-runtime-pid
if grep -n 'pidof.*sing-box' "$LIFECYCLE_UC" >/dev/null 2>&1; then
  fail "lifecycle.uc must not call 'pidof sing-box'; use tachyon-core-service-runtime-pid instead"
fi

if ! grep -n 'tachyon-core-service-runtime-pid' "$LIFECYCLE_UC" >/dev/null 2>&1; then
  fail "lifecycle.uc must query tachyon-core-service-runtime-pid for provenance"
fi

printf 'nft community subnets and lifecycle provenance invariant checks passed\n'
