#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
export TACHYON_SMART_EXCLUSIONS_DIR="$WORK_DIR/cache"
mkdir -p "$TACHYON_SMART_EXCLUSIONS_DIR"
export TACHYON_CORE_BIN="$WORK_DIR/decompiler"
export DECODE_FIXTURE="$WORK_DIR/decoded.json"
cat > "$TACHYON_CORE_BIN" <<'SH'
#!/bin/sh
[ "$1" = rule-set ] && [ "$2" = decompile ] && [ "$3" = --output ] || exit 1
cp "$DECODE_FIXTURE" "$4"
SH
chmod +x "$TACHYON_CORE_BIN"
printf 'SRS\001XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX' > "$WORK_DIR/preset.srs"
export EXCLUSION_SRS_FIXTURE="$WORK_DIR/preset.srs"
ucode -L "$TACHYON_LIB" "$ROOT_DIR/tests/smart_detect_exclusion_lists.uc"
