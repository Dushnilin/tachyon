#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
export TACHYON_LIB="$TACHYON_LIB"
RUNTIME="$TACHYON_LIB/diagnostics/runtime.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# doctor --fix used to call `component_action_async update_subscriptions update`.
# Neither the component nor the action exists, so the worker logged "Unknown
# component action" - but the launcher exits 0, so doctor reported success and
# the subscription was never touched. The fix has to launch the real entry
# point; this asserts the argv the branch actually runs, not the source text.
STUB="$WORK_DIR/tachyon-stub"
CALLS="$WORK_DIR/calls.log"
cat >"$STUB" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$CALLS"
exit 0
EOF
chmod +x "$STUB"

rm -f /tmp/tachyon_doctor_fixes.json

TACHYON_BIN="$STUB" ucode -L "$TACHYON_LIB" "$RUNTIME" apply-quick-fix "update_subscriptions" >/dev/null 2>&1 || true

if [ ! -s "$CALLS" ]; then
  fail "apply_quick_fix must launch the Tachyon CLI for update_subscriptions"
fi

calls="$(cat "$CALLS")"
printf 'invoked: %s\n' "$calls" >&2

case "$calls" in
  *subscription_update_async*) ;;
  *) fail "update_subscriptions must launch subscription_update_async" ;;
esac

case "$calls" in
  *component_action_async*)
    fail "update_subscriptions must not reach the component action dispatcher"
    ;;
esac

printf 'doctor subscription quick fix checks passed\n'
