#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RT="$ROOT_DIR/tachyon/files/usr/lib/diagnostics/runtime.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -f "$RT" ] || fail "runtime.uc not found"

# Doctor must attribute dead WireGuard/AWG tunnels to the outside world based
# on core log evidence, instead of leaving users to blame Tachyon for a peer
# that never answers (issues #39/#42 complaint pattern).
grep -Fq 'outbound/wireguard' "$RT" ||
  fail "doctor must scan core logs for wireguard outbound failures"
grep -Fq '"WireGuard/AWG tunnel"' "$RT" ||
  fail "doctor must report a dedicated WireGuard/AWG tunnel check"
grep -Fq 'проблема вне Tachyon' "$RT" ||
  fail "the verdict must state the failure is outside Tachyon"

# The check only speaks when there is evidence: no wireguard lines in the
# core log means no check line at all (no noise for non-AWG users).
grep -Fq 'if (wg_log != "" && wg_failures) {' "$RT" ||
  fail "failure verdict must require actual log evidence"
grep -Fq '} else if (wg_log != "") {' "$RT" ||
  fail "success line must be skipped entirely when no wireguard traffic exists"

printf 'doctor wireguard tunnel checks passed\n'
