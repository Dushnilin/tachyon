#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
ucode "$ROOT_DIR/tests/smart_detect_exclusion_refresh_build.uc" "$ROOT_DIR/tachyon/files/usr/lib/service/lifecycle.uc" "$ROOT_DIR/tachyon/files/usr/lib/components/updates.uc" "$ROOT_DIR/tests/smart_detect_exclusion_refresh.fixture.uc" "$WORK_DIR/test.uc"
ucode -L "$TACHYON_LIB" "$WORK_DIR/test.uc"
