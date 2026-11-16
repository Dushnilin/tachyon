#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

VALIDATOR="$ROOT_DIR/tachyon/files/usr/lib/config/validator.uc"

rows() {
  printf '%s\t%s\t%s\n' "$@"
}

assert_accepts() {
  local target="$1"
  shift 1

  rows "$@" | ucode -L "$TACHYON_LIB" "$VALIDATOR" validate-download-section "$target"
}

assert_rejects() {
  local label="$1"
  local expected="$2"
  local target="$3"
  shift 3
  local output

  if output="$(rows "$@" | ucode -L "$TACHYON_LIB" "$VALIDATOR" validate-download-section "$target" 2>/dev/null)"; then
    fail "$label should be rejected"
  fi

  printf '%s\n' "$output" | grep -Fq "$expected" ||
    fail "$label: expected message containing '$expected', got '$output'"
}

assert_accepts proxy proxy 1 proxy
assert_accepts outbound outbound 1 outbound
assert_accepts vpn vpn 1 vpn
assert_accepts des des 1 desync
assert_accepts csq csq 1 csqtt
assert_accepts ts ts 1 tailscale

assert_rejects "empty target" "no download section is selected" "" proxy 1 proxy
assert_rejects "missing target" "references missing rule 'missing'" missing proxy 1 proxy
assert_rejects "disabled target" "references disabled rule 'proxy'" proxy proxy 0 proxy
assert_rejects "removed provider rejected" "cannot provide an outbound" zap zap 1 zapret
assert_rejects "removed zapret2 rejected" "cannot provide an outbound" zap2 zap2 1 zapret2
assert_rejects "removed byedpi rejected" "cannot provide an outbound" bye bye 1 byedpi
assert_rejects "unsupported action" "cannot provide an outbound" bypass bypass 1 bypass

printf 'config validator download section checks passed\n'
