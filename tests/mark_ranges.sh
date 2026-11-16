#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

VALIDATOR="$TACHYON_LIB/config/validator.uc"

assert_no_overlap() {
  local label="$1"
  local mark="$2"
  local mask="$3"
  local mask_label="$4"

  if (( (mark & mask) != 0 )); then
    printf 'FAIL: %s mark 0x%08x overlaps %s 0x%08x\n' "$label" "$mark" "$mask_label" "$mask" >&2
    exit 1
  fi
}

assert_mark_range_no_overlap() {
  local label="$1"
  local base="$2"
  local range_size="$3"
  local mask="$4"
  local mask_label="$5"
  local index mark

  for ((index = 1; index <= range_size; index++)); do
    mark=$((base + index))
    assert_no_overlap "${label}[$index]" "$mark" "$mask" "$mask_label"
  done
}

eval "$(ucode -L "$TACHYON_LIB" "$TACHYON_LIB/core/constants.uc" shell-env)"

TAILSCALE_FWMARK_MASK=0x00ff0000

assert_no_overlap "FakeIP" "$((NFT_FAKEIP_MARK))" "$((TAILSCALE_FWMARK_MASK))" "Tailscale"
assert_no_overlap "outbound" "$((NFT_OUTBOUND_MARK))" "$((TAILSCALE_FWMARK_MASK))" "Tailscale"

cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": [ "77.88.8.8" ], "bootstrap_dns_server": [ "77.88.8.8" ] }
}
JSON

context_json() {
  local fakeip_mark="${1:-$NFT_FAKEIP_MARK}"
  local outbound_mark="${2:-$NFT_OUTBOUND_MARK}"

  cat <<JSON
{
  "community_services": "$COMMUNITY_SERVICES",
  "nft_fakeip_mark": "$fakeip_mark",
  "nft_outbound_mark": "$outbound_mark"
}
JSON
}

TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$VALIDATOR" validate-runtime-fixture "$WORK_DIR/fixture.json" "$(context_json)"

if TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$VALIDATOR" validate-runtime-fixture "$WORK_DIR/fixture.json" "$(context_json "0x00100000")" >/dev/null 2>&1; then
  fail "legacy FakeIP mark should overlap Tailscale fwmark mask"
fi
if TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$VALIDATOR" validate-runtime-fixture "$WORK_DIR/fixture.json" "$(context_json "" "0x00200000")" >/dev/null 2>&1; then
  fail "legacy outbound mark should overlap Tailscale fwmark mask"
fi

printf 'mark range checks passed\n'
