#!/usr/bin/env bash
# Verifies that clean installation / configure-service properly creates:
# 1. /etc/config/tachyon-core and sing-box.main section
# 2. /usr/share/tachyon-core working directory in managed_service_text and configure_service
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -euo pipefail

SB_RUNTIME="$TACHYON_LIB/tachyon_core/runtime.uc"
UCI_UC="$TACHYON_LIB/core/uci.uc"

[ -f "$SB_RUNTIME" ] || fail "tachyon_core/runtime.uc not found at $SB_RUNTIME"
[ -f "$UCI_UC" ] || fail "core/uci.uc not found at $UCI_UC"

# 1. ensure_sing_box_main_section creates /etc/config/tachyon-core
grep -Fq 'let cfg_file = "/etc/config/tachyon-core"' "$SB_RUNTIME" ||
  fail "ensure_sing_box_main_section must check and create /etc/config/tachyon-core if missing"

grep -Fq 'uci_set_option("tachyon-core", "main", "workdir", "/usr/share/tachyon-core")' "$SB_RUNTIME" ||
  fail "ensure_sing_box_main_section must set default workdir option"

# 2. managed_service_text creates working directory before launching sing-box
grep -Fq '[ -d \"$working_directory\" ] || mkdir -p \"$working_directory\"' "$SB_RUNTIME" ||
  fail "managed service init script must ensure working directory exists before running sing-box"

# 3. configure_service creates working directory
grep -Fq 'fs.mkdir(workdir, 0755)' "$SB_RUNTIME" ||
  fail "configure_service must ensure workdir directory exists"

# 4. core/uci.uc set_section creates missing config files
grep -Fq 'let cfg_file = "/etc/config/" + parts.package;' "$UCI_UC" ||
  fail "core/uci.uc set_section must create missing package file in /etc/config"

printf 'clean_install_sing_box_init: all checks passed\n'
