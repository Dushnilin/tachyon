#!/usr/bin/env bash
# Verify generated DNS block records for the supported core profiles. Set
# TACHYON_TEST_SING_BOX_BIN to also check and query a real sing-box binary.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -euo pipefail

if [ -n "${TACHYON_TEST_SING_BOX_BIN:-}" ]; then
  acquire_core_proc_lock
  trap 'release_core_proc_lock; cleanup' EXIT
fi

python3 "$ROOT_DIR/tests/lib/dns_block_predefined.py" "$TACHYON_LIB" "$WORK_DIR"
