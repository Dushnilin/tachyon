#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
export TACHYON_SMART_ACTIONS_DIR="$WORK_DIR/receipts"
export TACHYON_PSL_FILE="$ROOT_DIR/tachyon/files/usr/share/tachyon/public-suffix-list.dat"
ucode "$ROOT_DIR/tests/smart_detect_actions_build.uc" \
  "$TACHYON_LIB/service/telegram/smart_detect_actions.uc" \
  "$ROOT_DIR/tests/smart_detect_actions.fixture.uc" "$WORK_DIR/actions.uc" \
  "$TACHYON_LIB/service/telegram/runtime.uc"
ucode -S -L "$TACHYON_LIB" "$WORK_DIR/actions.uc"
